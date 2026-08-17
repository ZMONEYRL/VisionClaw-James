/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionViewModel.swift
//
// Core view model demonstrating video streaming from Meta wearable devices using the DAT SDK.
// This class showcases the key streaming patterns: device selection, session management,
// video frame handling, photo capture, and error handling.
//

import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import MWDATCamera
import MWDATCore
import SwiftUI
import VideoToolbox

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

enum StreamingMode {
  case glasses
  case iPhone
}

@MainActor
class StreamSessionViewModel: ObservableObject {
  @Published var currentVideoFrame: UIImage?
  @Published var hasReceivedFirstFrame: Bool = false
  @Published var streamingStatus: StreamingStatus = .stopped
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published var hasActiveDevice: Bool = false
  @Published var streamingMode: StreamingMode = .glasses
  @Published var selectedResolution: StreamingResolution = .high

  var isStreaming: Bool {
    streamingStatus != .stopped
  }

  var resolutionLabel: String {
    switch selectedResolution {
    case .low: return "360x640"
    case .medium: return "504x896"
    case .high: return "720x1280"
    @unknown default: return "Unknown"
    }
  }

  // Photo capture properties
  @Published var capturedPhoto: UIImage?
  @Published var showPhotoPreview: Bool = false

  // The core DAT SDK StreamSession - handles all streaming operations.
  // nil when the Wearables SDK is unavailable (simulator, or a build without
  // glasses); the iPhone camera path never touches it.
  private var streamSession: StreamSession?
  // Listener tokens are used to manage DAT SDK event subscriptions
  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?
  private let wearables: WearablesInterface?
  private let deviceSelector: AutoDeviceSelector?
  private var deviceMonitorTask: Task<Void, Never>?
  // CPU-based CIContext for rendering decoded pixel buffers in background
  private let cpuCIContext = CIContext(options: [.useSoftwareRenderer: true])
  // VideoDecoder for decompressing HEVC/H.264 frames in background
  private let videoDecoder = VideoDecoder()
  private var backgroundFrameCount = 0
  private var bgDiagLogged = false

  init(wearables: WearablesInterface?) {
    self.wearables = wearables

    if let wearables {
      // Let the SDK auto-select from available devices
      let selector = AutoDeviceSelector(wearables: wearables)
      self.deviceSelector = selector
      // 720x1280 rather than 360x640. At the low tier, printed text is a few
      // pixels tall before JPEG compression halves it again -- the model could
      // read a receipt's header and total but nothing smaller. Must match
      // `selectedResolution` below; the two are set independently.
      let config = StreamSessionConfig(
        videoCodec: VideoCodec.raw,
        resolution: StreamingResolution.high,
        frameRate: 24)
      streamSession = StreamSession(streamSessionConfig: config, deviceSelector: selector)

      // Monitor device availability
      deviceMonitorTask = Task { @MainActor in
        for await device in selector.activeDeviceStream() {
          self.hasActiveDevice = device != nil
        }
      }
    } else {
      self.deviceSelector = nil
    }

    setupVideoDecoder()
    attachListeners()
  }

  /// Bridge to the LiveKit call: every decoded glasses frame is also handed
  /// here, so the room publishes exactly what the glasses see.
  var onDecodedFrame: ((CVPixelBuffer) -> Void)?

  private func setupVideoDecoder() {
    videoDecoder.setFrameCallback { [weak self] decodedFrame in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let pixelBuffer = decodedFrame.pixelBuffer
        self.onDecodedFrame?(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if let cgImage = self.cpuCIContext.createCGImage(ciImage, from: rect) {
          let image = UIImage(cgImage: cgImage)
          // The decoded background path — James keeps seeing while the phone
          // is in a pocket, which is the whole point of glasses.
          JamesEye.shared.offer(image)
          if self.backgroundFrameCount <= 5 || self.backgroundFrameCount % 120 == 0 {
            NSLog("[Stream] Background frame #%d decoded and forwarded (%dx%d)",
                  self.backgroundFrameCount, width, height)
          }
        }
      }
    }
  }

  /// Recreate the StreamSession with the current selectedResolution.
  /// Only call when not actively streaming.
  func updateResolution(_ resolution: StreamingResolution) {
    guard !isStreaming, let deviceSelector else { return }
    selectedResolution = resolution
    let config = StreamSessionConfig(
      videoCodec: VideoCodec.raw,
      resolution: resolution,
      frameRate: 24)
    streamSession = StreamSession(streamSessionConfig: config, deviceSelector: deviceSelector)
    attachListeners()
    NSLog("[Stream] Resolution changed to %@", resolutionLabel)
  }

  private func attachListeners() {
    guard let streamSession else { return }
    // Subscribe to session state changes using the DAT SDK listener pattern
    stateListenerToken = streamSession.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        self?.updateStatusFromState(state)
      }
    }

    // Subscribe to video frames from the device camera
    // This callback fires whether the app is in the foreground or background,
    // enabling continuous streaming even when the screen is locked.
    videoFrameListenerToken = streamSession.videoFramePublisher.listen { [weak self] videoFrame in
      Task { @MainActor [weak self] in
        guard let self else { return }

        let isInBackground = UIApplication.shared.applicationState == .background

        if !isInBackground {
          self.backgroundFrameCount = 0
          self.bgDiagLogged = false
          if let image = videoFrame.makeUIImage() {
            self.currentVideoFrame = image
            JamesEye.shared.offer(image)
            if !self.hasReceivedFirstFrame {
              self.hasReceivedFirstFrame = true
            }
          }
        } else {
          // In background: makeUIImage() uses VideoToolbox GPU rendering which iOS suspends.
          // Instead, use our VideoDecoder (VTDecompressionSession) to decode compressed
          // frames into pixel buffers, then convert via CPU CIContext.
          self.backgroundFrameCount += 1

          let sampleBuffer = videoFrame.sampleBuffer
          let hasCompressedData = CMSampleBufferGetDataBuffer(sampleBuffer) != nil

          if hasCompressedData {
            // Compressed frame (HEVC/H.264) - decode via VTDecompressionSession
            do {
              try self.videoDecoder.decode(sampleBuffer)
            } catch {
              if self.backgroundFrameCount <= 5 || self.backgroundFrameCount % 120 == 0 {
                NSLog("[Stream] Background frame #%d decode error: %@",
                      self.backgroundFrameCount, String(describing: error))
              }
            }
          } else if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            self.onDecodedFrame?(pixelBuffer)
            // Raw pixel buffer - convert directly via CPU CIContext
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            if let cgImage = self.cpuCIContext.createCGImage(ciImage, from: rect) {
              JamesEye.shared.offer(UIImage(cgImage: cgImage))
            }
            self.videoDecoder.invalidateSession()
          }
        }
      }
    }

    // Subscribe to streaming errors
    errorListenerToken = streamSession.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        // One voice: glasses-state conditions render as placeholder text on
        // the call screen, never as alert dialogs. Sleeping/absent glasses are
        // a plain wait; everything else maps to a typed issue.
        switch error {
        case .deviceNotConnected, .deviceNotFound:
          self.glassesIssue = nil
        case .hingesClosed:
          self.glassesIssue = .hingesClosed
        case .permissionDenied:
          self.glassesIssue = .permissionNeeded
        default:
          self.glassesIssue = .reconnecting
        }
      }
    }

    updateStatusFromState(streamSession.state)

    // Subscribe to photo capture events
    photoDataListenerToken = streamSession.photoDataPublisher.listen { [weak self] photoData in
      Task { @MainActor [weak self] in
        guard let self else { return }
        guard let uiImage = UIImage(data: photoData.data) else { return }
        self.capturedPhoto = uiImage
        self.showPhotoPreview = true
      }
    }
  }

  /// Glasses-state conditions the call screen's placeholder can name --
  /// the app's own voice, replacing the sample's alert dialogs.
  enum GlassesIssue: Equatable {
    case sdkUnavailable
    case permissionNeeded
    case hingesClosed
    case reconnecting
  }

  @Published var glassesIssue: GlassesIssue?

  func handleStartStreaming() async {
    glassesIssue = nil
    guard let wearables else {
      glassesIssue = .sdkUnavailable
      return
    }
    let permission = Permission.camera
    do {
      let status = try await wearables.checkPermissionStatus(permission)
      if status == .granted {
        await startSession()
        return
      }
      let requestStatus = try await wearables.requestPermission(permission)
      if requestStatus == .granted {
        await startSession()
        return
      }
      glassesIssue = .permissionNeeded
    } catch {
      // Sleeping or out-of-range glasses are a wait state, not an error.
      let text = String(describing: error).lowercased()
      if text.contains("powered off") || text.contains("disconnected") || text.contains("no device") {
        NSLog("[Stream] glasses unavailable, waiting: %@", String(describing: error))
        glassesIssue = nil
      } else {
        glassesIssue = .reconnecting
      }
    }
  }

  func startSession() async {
    // Forwarding follows the stream: this build exists to give James eyes, so
    // starting the glasses starts the sending. The real off-switch is the
    // config — with no endpoint compiled in, JamesEye never sends anything.
    JamesEye.shared.isEnabled = true
    await streamSession?.start()
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  func stopSession() async {
    JamesEye.shared.isEnabled = false
    await streamSession?.stop()
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func capturePhoto() {
    streamSession?.capturePhoto(format: .jpeg)
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  private func updateStatusFromState(_ state: StreamSessionState) {
    switch state {
    case .stopped:
      currentVideoFrame = nil
      streamingStatus = .stopped
    case .waitingForDevice, .starting, .stopping, .paused:
      streamingStatus = .waiting
    case .streaming:
      streamingStatus = .streaming
      glassesIssue = nil
    }
  }

  private func formatStreamingError(_ error: StreamSessionError) -> String {
    switch error {
    case .internalError:
      return "An internal error occurred. Please try again."
    case .deviceNotFound:
      return "Device not found. Please ensure your device is connected."
    case .deviceNotConnected:
      return "Device not connected. Please check your connection and try again."
    case .timeout:
      return "The operation timed out. Please try again."
    case .videoStreamingError:
      return "Video streaming failed. Please try again."
    case .audioStreamingError:
      return "Audio streaming failed. Please try again."
    case .permissionDenied:
      return "Camera permission denied. Please grant permission in Settings."
    case .hingesClosed:
      return "The hinges on the glasses were closed. Please open the hinges and try again."
    @unknown default:
      return "An unknown streaming error occurred."
    }
  }
}

// MARK: - James

/// Sends what the glasses see to James.
///
/// James already has the eye: his dashboard accepts a raw JPEG on
/// POST /api/camera/frame, writes it atomically to camera-latest.jpg, and
/// treats anything under 8 seconds old as "what Zee is looking at right now".
/// So there is very little to do here — throttle, encode, post, forget.
///
/// Deliberately no queue and no retries. A frame that failed to send is
/// already stale, and the next one is a second behind it; a backlog of old
/// frames arriving late is strictly worse than a gap.
///
/// This lives at the bottom of an existing file on purpose. Adding a new
/// Swift file means editing project.pbxproj by hand, which is UUID-keyed and
/// unverifiable without opening Xcode — a needless way to break the build.
@MainActor
final class JamesEye {
  static let shared = JamesEye()

  // Filled in by CI from repository secrets, so the key never lands in git.
  // To run a local build, put your own values here.
  static let endpoint = "__JAMES_URL__"
  static let key = "__JAMES_KEY__"

  /// One frame a second — comfortably inside James's 8-second freshness
  /// window, and far short of writing a video feed into a vault folder.
  private let interval: TimeInterval = 1.0
  /// JPEG quality. VisionClaw sends Gemini 50%; James's endpoint caps a frame
  /// at 12MB, so this is about bandwidth over a phone link, not the limit.
  private let quality: CGFloat = 0.5

  private var lastSent = Date.distantPast
  private var inFlight = false

  /// Set while a glasses stream is running, cleared when it stops.
  var isEnabled = false

  private var url: URL? {
    guard !Self.endpoint.hasPrefix("__"), !Self.endpoint.isEmpty else { return nil }
    return URL(string: Self.endpoint)
  }

  func offer(_ image: UIImage) {
    guard isEnabled, !inFlight, let url else { return }
    let now = Date()
    guard now.timeIntervalSince(lastSent) >= interval else { return }
    guard let jpeg = image.jpegData(compressionQuality: quality) else { return }

    lastSent = now
    inFlight = true

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
    request.setValue(Self.key, forHTTPHeaderField: "X-James-Key")
    // Shorter than the send interval: a request still hanging when the next
    // frame is due is a request worth abandoning.
    request.timeoutInterval = 0.9

    URLSession.shared.uploadTask(with: request, from: jpeg) { _, response, error in
      Task { @MainActor in JamesEye.shared.inFlight = false }
      if let error {
        NSLog("[James] frame not sent: %@", error.localizedDescription)
      } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
        // 403 here means the key is wrong or lan_access is off on the PC.
        NSLog("[James] frame refused: HTTP %d", http.statusCode)
      }
    }.resume()
  }
}
