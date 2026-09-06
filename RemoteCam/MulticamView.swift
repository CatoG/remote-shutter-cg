//
//  MulticamView.swift
//  RemoteShutter
//
//  Copyright © 2026 Security Union LLC. All rights reserved.
//

import MPCCompat
import SwiftUI

/// The director screen in focus mode: the selected camera fills the viewfinder
/// (reusing the 1:1 monitor's `LiveFrameView` so it looks and behaves the same),
/// with the zoom stops railed on the trailing edge and the framing controls in
/// the bottom-trailing corner. Grid mode is the monitor wall over the same
/// chrome; it is the only surface that shows the rig's other cameras.
struct MulticamView: View {
    @ObservedObject var viewModel: MulticamViewModel

    /// Tap a grid tile to make that camera the focused one.
    let onFocusLane: (CameraLane) -> Void
    /// Rig self-timer changed (seconds; 0 = off).
    let onSetTimer: (Int) -> Void
    /// Rig video quality picked (fans out to every lane).
    let onSelectVideoQuality: (VideoResolution, VideoFrameRate) -> Void
    /// "Automatic" — recompute best-in-intersection and apply.
    let onAutomaticVideoQuality: () -> Void
    /// Rig photo format / HDR picked.
    let onSetPhotoFormat: (PhotoFormat) -> Void
    let onSetHDR: (Bool) -> Void
    /// Rig aspect ratio picked (one crop across every camera).
    let onSetAspectRatio: (AspectRatio) -> Void
    /// Rig standby: blank (or wake) every supporting camera's own preview.
    let onSetStandby: (Bool) -> Void
    /// Open the app's Settings sheet (purchases, restore, preferences).
    let onOpenSettings: () -> Void
    /// Open the help sheet (the shared one every screen presents).
    let onOpenHelp: () -> Void
    /// Retry a lane's failed footage collection.
    let onRetryCollection: (CameraLane) -> Void
    /// Flip the focused camera front/back (per-camera framing).
    /// Per-camera commands carry the lane they were rendered for — routing is
    /// a parameter of the command, never a stored register.
    let onFlipCamera: (CameraLane) -> Void
    /// Torch on the named camera (per-camera framing).
    let onToggleTorch: (CameraLane) -> Void
    /// Disconnect one camera from the rig (long-press → EndSession to it).
    let onDisconnectCamera: (CameraLane) -> Void
    /// Zoom the named camera (per-camera framing; throttled by the host).
    let onZoomChange: (CameraLane, CGFloat) -> Void
    /// Tap-to-focus on the named camera (normalized upright coords; the host
    /// gates on the IAP, the controller on the peer's advertised support).
    let onFocusTap: (CameraLane, CGPoint) -> Void
    /// Leave the director screen, back to the scanner (links stay up; the
    /// scanner re-arms and re-selects the still-connected cameras).
    let onBack: () -> Void

    var body: some View {
        GeometryReader { geo in
            let dock = MonitorChromeLayout.dock(
                viewSize: geo.size,
                interfaceOrientation: viewModel.interfaceOrientation,
                input: chromeInput)

            ZStack {
                Color.black.ignoresSafeArea(edges: Self.previewBleedEdges)

                if viewModel.displayMode == .grid {
                    gridWall(in: geo.size)
                } else {
                    focusedViewfinder
                }

                // Same chrome skeleton as the 1:1 monitor: a top bar, then the
                // docked action cluster on the home-indicator edge. The zoom
                // rail and the framing corner are laid over that skeleton
                // rather than inside its column, so both stay pinned to the
                // trailing edge whichever way the cluster docks.
                chrome(dock: dock)
                zoomRail(dock: dock)
                framingCorner
                countdownOverlay
                transientErrorToast
                if viewModel.showingRigTray { rigTrayLayer }

                #if DEBUG
                SessionDebugOverlay()
                #endif
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: viewModel.showingRigTray)
        }
        // Catalyst's default style paints a bordered box behind controls that
        // already draw their own shape. Not .plain — that also drops the
        // style's hit region, leaving material fills unclickable.
        .buttonStyle(.borderless)
        .statusBarHidden()
    }

    /// iPhone/iPad draw the preview full-bleed under the notch and the home
    /// indicator. The Mac's toolbar (Back button, window title) is opaque
    /// chrome — the preview must never draw under it.
    private static var previewBleedEdges: Edge.Set {
        #if targetEnvironment(macCatalyst)
        []
        #else
        .all
        #endif
    }

    /// The rig tray in the classic monitor's glass presentation: a near-invisible
    /// dismiss scrim (so the preview stays framed) under the floating panel.
    private var rigTrayLayer: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.02)
                .ignoresSafeArea()
                .onTapGesture { viewModel.showingRigTray = false }
            RigTrayPanel(settings: viewModel.rigSettings,
                         mode: viewModel.mode,
                         isRecording: viewModel.isRecording,
                         onSetTimer: onSetTimer,
                         onSelectVideoQuality: onSelectVideoQuality,
                         onAutomaticVideoQuality: onAutomaticVideoQuality,
                         onSetPhotoFormat: onSetPhotoFormat,
                         onSetHDR: onSetHDR,
                         onSetAspectRatio: onSetAspectRatio,
                         onSetStandby: onSetStandby,
                         // Close the tray first, as the 1:1 tray does — the
                         // sheet returns to a clean viewfinder.
                         onOpenSettings: {
                             viewModel.showingRigTray = false
                             onOpenSettings()
                         },
                         onOpenHelp: {
                             viewModel.showingRigTray = false
                             onOpenHelp()
                         })
                .transition(.move(edge: .bottom))
        }
    }

    // MARK: - Chrome (mirrors MonitorView's chrome, slot for slot)

    /// Everything floating over the preview, arranged for the docked edge —
    /// the same skeleton the 1:1 monitor uses (`topBar`, spacer, docked
    /// cluster) with the same padding, so the two screens read identically.
    private func chrome(dock: MonitorChromeDock) -> some View {
        VStack(spacing: 0) {
            topBar

            Spacer(minLength: 0)

            switch dock {
            case .bottom: bottomCluster
            case .leading: sideCluster(onLeading: true)
            case .trailing: sideCluster(onLeading: false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    /// Back (leading) · focused link + camera chip · Spacer · torch/tray, with
    /// the recording timecode centered over it all — the same slots as the
    /// monitor's `topBar`; the rig tray takes the settings glyph's place.
    private var topBar: some View {
        ZStack {
            // Focus mode: the focused camera fills the screen, so its tile
            // timer sits where its tile's top edge is — top bar, centered.
            // Grid mode draws one on each tile instead. Either way the value
            // is that camera's own tick; no rig-wide time exists.
            if viewModel.displayMode != .grid,
               let focused = viewModel.focusedLane, focused.isRecording {
                LaneRecordingTimer(elapsedMillis: focused.recordingElapsedMillis)
            }
            topBarControls
        }
    }

    private var topBarControls: some View {
        HStack(spacing: 0) {
            GlassCircleButton(systemImage: "chevron.backward",
                              size: 44, glyphSize: 22,
                              isEnabled: !viewModel.isRecording,
                              action: onBack)
            LinkChip(state: viewModel.focusedLinkState)
                .equatable()
                .padding(.leading, 8)
            focusedCameraChip
                .padding(.leading, 8)
            Spacer(minLength: 0)
            // No flash: the director's capsule carries the torch and the tray
            // only. The 1:1 monitor still shows flash — that is what the
            // `showsFlash` slot is for.
            ControlCapsule(showsFlash: false,
                           showsTorch: viewModel.showsTorchButton,
                           isFlashEnabled: false,
                           isFlashButtonEnabled: false,
                           isTorchEnabled: viewModel.focusedTorchOn,
                           isTorchButtonEnabled: viewModel.focusedTorchEnabled,
                           isTrayOpen: viewModel.showingRigTray,
                           onToggleFlash: {},
                           onToggleTorch: withFocused(onToggleTorch),
                           onToggleTray: {
                               logInfo("director: rig tray opened")
                               viewModel.showingRigTray = true
                           })
                .equatable()
        }
    }

    /// The focused camera's name, and — via long-press — "Disconnect Camera",
    /// the same purposeful goodbye offered on each strip thumbnail.
    @ViewBuilder
    private var focusedCameraChip: some View {
        if let focused = viewModel.focusedLane {
            Text(focused.displayName)
                .font(.caption)
                .foregroundColor(.white.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.ultraThinMaterial))
                .contextMenu { disconnectButton(for: focused) }
        }
    }

    /// Portrait and other tall shapes: the action cluster sits on the bottom
    /// edge — the monitor's `bottomCluster`, now carrying the grid toggle
    /// alone.
    private var bottomCluster: some View {
        actionCluster(axis: .horizontal)
    }

    /// Wide shapes: the action cluster rides the docked rail — the monitor's
    /// `sideCluster` shape.
    private func sideCluster(onLeading: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            if onLeading {
                actionCluster(axis: .vertical)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                actionCluster(axis: .vertical)
            }
        }
    }

    /// The grid toggle, in the monitor's gallery slot. The shutter and the
    /// camera-switch slots are gone from this cluster: the director does not
    /// capture, and flip has moved to `framingCorner`.
    private func actionCluster(axis: Axis) -> some View {
        Group {
            if axis == .horizontal {
                gridToggleButton.frame(maxWidth: .infinity)
            } else {
                gridToggleButton.frame(maxHeight: .infinity)
            }
        }
    }

    /// The focused camera's zoom, railed vertically on the trailing edge and
    /// centred over the picture. Per-camera framing, so it shows in focus mode
    /// only, and hides when the focused camera has no usable zoom range (a
    /// fixed-focal-length camera, or before its first response), exactly as the
    /// 1:1 monitor does.
    ///
    /// On a trailing dock the action cluster already owns that edge, so the
    /// rail steps inboard by one button plus the cluster's own gap rather than
    /// stacking on top of it.
    @ViewBuilder
    private func zoomRail(dock: MonitorChromeDock) -> some View {
        if viewModel.displayMode == .focus && viewModel.showsFocusedZoomPill,
           let focused = viewModel.focusedLane {
            ZoomPill(scale: viewModel.focusedZoomScale,
                     currentZoomFactor: viewModel.focusedZoomFactor,
                     onZoomChange: { onZoomChange(focused, $0) },
                     axis: .vertical)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, dock == .trailing ? Self.railClearance : 0)
                .padding(.horizontal, 16)
        }
    }

    /// How far the zoom rail steps in when the action cluster rails on the same
    /// edge: one 44pt control plus the `sideCluster` gap.
    private static let railClearance: CGFloat = 44 + 16

    /// Map a tap made over a mirrored preview back into true image
    /// coordinates. Normalized, origin top-left, so each flipped axis is its
    /// own subtraction from 1.
    static func unmirrored(_ point: CGPoint,
                           horizontally: Bool,
                           vertically: Bool) -> CGPoint {
        CGPoint(x: horizontally ? 1 - point.x : point.x,
                y: vertically ? 1 - point.y : point.y)
    }

    /// The two mirrors and the camera flip, pinned to the bottom-trailing
    /// corner. Flip stays outermost — it is the control the thumb reaches for
    /// — with the mirrors inboard of it, so adding one never moves the others.
    private var framingCorner: some View {
        HStack(spacing: 12) {
            mirrorVerticalButton
            mirrorHorizontalButton
            CameraSwitchControlView(
                control: .flipButton,
                devices: [],
                activeDeviceID: nil,
                isEnabled: viewModel.focusedCameraCanFlip,
                isSwitching: false,
                onToggleCamera: withFocused(onFlipCamera),
                onSelectCameraDevice: { _ in })
                .equatable()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// Flip the preview left-for-right. A monitor-side view transform: no
    /// command goes to the cameras, so it stays live even while a link is
    /// down, and it never changes what any camera records.
    private var mirrorHorizontalButton: some View {
        GlassCircleButton(
            systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right",
            size: 44, glyphSize: 20,
            isActive: viewModel.mirroredHorizontally,
            isEnabled: true,
            action: {
                viewModel.mirroredHorizontally.toggle()
                logInfo("director: preview mirrored ↔ → \(viewModel.mirroredHorizontally)")
            })
    }

    /// The same transform about the other axis — top-for-bottom. Its own
    /// toggle rather than a shared cycle, so an upside-down camera can be
    /// corrected with one press and left that way.
    private var mirrorVerticalButton: some View {
        GlassCircleButton(
            systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down",
            size: 44, glyphSize: 20,
            isActive: viewModel.mirroredVertically,
            isEnabled: true,
            action: {
                viewModel.mirroredVertically.toggle()
                logInfo("director: preview mirrored ↕ → \(viewModel.mirroredVertically)")
            })
    }

    /// Bind a per-camera action to the lane the control was rendered for.
    private func withFocused(_ action: @escaping (CameraLane) -> Void) -> () -> Void {
        { if let focused = viewModel.focusedLane { action(focused) } }
    }

    /// The grid toggle occupies the monitor's gallery slot. Shown only with
    /// more than one camera; otherwise an empty 44pt frame holds the slot open,
    /// exactly as the monitor's hidden-control spacer does.
    @ViewBuilder
    private var gridToggleButton: some View {
        if MultiCamChrome.showsGridToggle(cameraCount: viewModel.lanes.count) {
            GlassCircleButton(
                systemImage: viewModel.displayMode == .grid
                    ? "rectangle.inset.filled" : "square.grid.2x2.fill",
                size: 44, glyphSize: 20,
                isActive: viewModel.displayMode == .grid,
                isEnabled: true,
                action: {
                    viewModel.displayMode = viewModel.displayMode == .grid ? .focus : .grid
                    logInfo("director: display mode → \(viewModel.displayMode)")
                })
        } else {
            Color.clear.frame(width: 44, height: 44)
        }
    }

    /// "Disconnect Camera" — a purposeful goodbye to one camera. Long-press on
    /// the focused camera's name chip.
    private func disconnectButton(for lane: CameraLane) -> some View {
        Button(role: .destructive, action: { onDisconnectCamera(lane) }) {
            Label(NSLocalizedString("Disconnect Camera", comment: "remove one camera from the rig"),
                  systemImage: "xmark.circle")
        }
    }

    /// How long the error toast dwells. Apple publishes no toast API or
    /// constant; the anchors are the system notification banner's ~5s dwell
    /// and the accessibility floor of 5 seconds minimum for reading a
    /// sentence of transient text.
    private static let errorToastSeconds: UInt64 = 5

    /// A brief error readout (a refused camera switch, e.g.) in the chrome's
    /// glass style, tucked under the top bar. Non-blocking — it never
    /// hit-tests, and it fades itself out; deliberately not a modal.
    @ViewBuilder
    private var transientErrorToast: some View {
        if let error = viewModel.transientError {
            Text(error.message)
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(.ultraThinMaterial))
                .allowsHitTesting(false)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 64)
                .transition(.opacity)
                .id(error.id)
                .task(id: error.id) {
                    try? await Task.sleep(nanoseconds: Self.errorToastSeconds * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        // Clear only the toast this dwell belongs to — a
                        // newer report keeps its own full dwell.
                        if viewModel.transientError?.id == error.id {
                            viewModel.transientError = nil
                        }
                    }
                }
        }
    }

    /// The rig self-timer countdown, big and centered so subjects see it. The
    /// number must read against whatever the cameras are pointed at: two
    /// shadows — one tight for edge definition, one wide for separation —
    /// keep it legible without a backing plate, and it never steals a tap
    /// from the viewfinder.
    @ViewBuilder
    private var countdownOverlay: some View {
        if let n = viewModel.rigSettings.countdown, n > 0 {
            Text("\(n)")
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .foregroundColor(AppTheme.accent)
                .shadow(color: .black.opacity(0.85), radius: 3)
                .shadow(color: .black.opacity(0.55), radius: 16)
                .id(n)
                .transition(.scale(scale: 1.15).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }

    /// An equal grid of every camera — the monitor wall. Tap a tile to focus it
    /// (and return to focus mode). Cells are sized to the viewport — rows ×
    /// columns always fit the window on any shape, and each tile letterboxes
    /// its video (`LiveFrameView` draws `.fit`).
    private func gridWall(in size: CGSize) -> some View {
        let count = viewModel.lanes.count
        let rows = MultiCamChrome.gridRowCount(cameraCount: count)
        let spacing: CGFloat = 4
        let padding: CGFloat = 8
        let cellHeight = max(1, (size.height - padding * 2 - spacing * CGFloat(rows - 1)) / CGFloat(rows))
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: spacing),
            count: MultiCamChrome.gridColumnCount(cameraCount: count))
        return LazyVGrid(columns: columns, spacing: spacing) {
            ForEach(viewModel.lanes) { lane in
                CameraTileView(lane: lane, isThumbnail: true,
                               aspectRatio: viewModel.rigSettings.aspectRatio,
                               mirroredHorizontally: viewModel.mirroredHorizontally,
                               mirroredVertically: viewModel.mirroredVertically,
                               onRetry: { onRetryCollection(lane) })
                    .frame(height: cellHeight)
                    .onTapGesture {
                        onFocusLane(lane)
                        viewModel.displayMode = .focus
                    }
            }
        }
        .padding(padding)
    }

    private var chromeInput: MonitorChromeInput {
        #if targetEnvironment(macCatalyst)
        return .pointer
        #else
        return .touch
        #endif
    }

    @ViewBuilder
    private var focusedViewfinder: some View {
        if let focused = viewModel.focusedLane {
            // One ZStack, one `ignoresSafeArea`: the frame, the gestures, and
            // the reticle share a single coordinate space (the same contract as
            // the 1:1 monitor's preview layer). Gestures address the focused
            // camera; in grid mode a tile tap focuses the lane instead.
            ZStack {
                LiveFrameView(frames: focused.frames,
                              aspectRatio: viewModel.rigSettings.aspectRatio,
                              mirroredHorizontally: viewModel.mirroredHorizontally,
                              mirroredVertically: viewModel.mirroredVertically)
                ViewfinderGestureLayer(
                    cameraImage: { focused.frames.cameraImage },
                    zoomScale: { focused.zoomScale },
                    currentZoomFactor: { focused.zoomFactor },
                    focusEnabled: focused.supportsFocusPoint,
                    // The gesture layer measures the untransformed view, so a
                    // mirrored preview puts the picture under the finger at the
                    // opposite x, y, or both. Undo the flips before the point
                    // leaves the screen; the camera only ever sees true image
                    // coordinates.
                    onFocusTap: {
                        onFocusTap(focused,
                                   Self.unmirrored($0,
                                                   horizontally: viewModel.mirroredHorizontally,
                                                   vertically: viewModel.mirroredVertically))
                    },
                    onDoubleTap: { onFlipCamera(focused) },
                    onZoomChange: { onZoomChange(focused, $0) })
            }
            .ignoresSafeArea(edges: Self.previewBleedEdges)
        } else {
            // No camera focused yet (all reconnecting, or none linked).
            Rectangle()
                .fill(Color.gray.opacity(0.25))
                .overlay(
                    Image(systemName: "video.slash")
                        .font(.system(size: 44))
                        .foregroundColor(.white.opacity(0.5)))
                .ignoresSafeArea(edges: Self.previewBleedEdges)
        }
    }
}

/// The single status a tile shows, coalesced from the lane's capture and
/// collection state so a synced photo (both captured AND collected) reads as
/// one green check, never two overlapping glyphs.
enum TileStatus: Equatable {
    case none
    case reconnecting
    case recording
    case transferring(Double)
    case success        // captured and/or collected — one confirmation
    case captureFailed  // the shot nacked; not retryable from the tile
    case transferFailed // footage collection failed; tap to retry
    case needsRematch   // can't match the running rig quality

    /// Success confirmations are transient — they fade off the tile.
    var isTransient: Bool { self == .success }

    /// Priority ladder (highest first): failed > reconnecting > transferring >
    /// REC > success > rematch > nothing. `includeSuccess: false` yields the
    /// resting status the tile falls back to once a success confirmation fades.
    static func resolve(status: CameraLink.Status,
                        captureOutcome: CaptureOutcome?,
                        isRecording: Bool,
                        collection: CameraLink.LaneCollectionState,
                        needsQualityRematch: Bool,
                        includeSuccess: Bool = true) -> TileStatus {
        if collection == .failed { return .transferFailed }
        if captureOutcome == .failed { return .captureFailed }
        if status == .reconnecting { return .reconnecting }
        if case .transferring(let progress) = collection { return .transferring(progress) }
        if isRecording { return .recording }
        if includeSuccess, collection == .collected || captureOutcome == .captured { return .success }
        if needsQualityRematch { return .needsRematch }
        return .none
    }
}

/// One corner badge, one glyph, on a glass circle with a surface ring so it
/// reads cleanly over any frame — the fix for the overlapping-checks blob.
struct TileStatusBadge: View {
    let status: TileStatus
    let onRetry: (() -> Void)?
    /// Smaller on strip/grid thumbnails, full size on a focused tile.
    var diameter: CGFloat = 28

    var body: some View {
        switch status {
        case .none, .reconnecting:
            EmptyView()
        case .transferFailed:
            Button { onRetry?() } label: { chip("arrow.clockwise.icloud", tint: .white) }
        case .captureFailed:
            chip("exclamationmark.triangle.fill", tint: .yellow)
        case .needsRematch:
            chip("exclamationmark.triangle.fill", tint: .yellow)
        case .recording:
            chip("record.circle.fill", tint: .red)
        case .transferring(let progress):
            chip(nil, tint: .white, progress: progress)
        case .success:
            chip("checkmark.circle.fill", tint: .green)
        }
    }

    /// A glass circle with a 2px surface ring; either an SF Symbol or a
    /// determinate progress ring.
    private func chip(_ symbol: String?, tint: Color, progress: Double? = nil) -> some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 2)
            if let progress {
                Circle().trim(from: 0, to: max(0.02, progress))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(4)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: diameter * 0.54, weight: .semibold))
                    .foregroundColor(tint)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// One camera's tile: its isolated live frame, a name chip, a focus ring, and
/// a reconnecting scrim. `Equatable` on the value inputs so a frame delivered
/// to another lane can't invalidate this tile's chrome — only its own
/// `LiveFrameView` (observing its own `FrameDisplayModel`) re-renders.
/// One camera's timer capsule — its own tick, verbatim. Shared by the grid
/// tiles and the focus-mode top bar so the timer reads identically wherever
/// that camera is shown.
struct LaneRecordingTimer: View {
    let elapsedMillis: UInt64?
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.red)
                .frame(width: compact ? 6 : 8, height: compact ? 6 : 8)
            Text(RecordingTimer.format(elapsedMillis))
                .font(.system(size: compact ? 10 : 13,
                              weight: .bold, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.6))
        .clipShape(Capsule())
    }
}

struct CameraTileView: View {
    @ObservedObject var lane: CameraLane
    var isThumbnail: Bool = false
    /// The rig's aspect ratio — the tile draws the same crop bars as the
    /// focused viewfinder, so every angle is judged against the real frame.
    var aspectRatio: AspectRatio = .sixteenNine
    /// Draw the picture flipped, matching the focused viewfinder. Only the
    /// frame mirrors — the name chip, timer and status badge stay readable.
    var mirroredHorizontally: Bool = false
    var mirroredVertically: Bool = false
    /// Retry a failed footage collection for this lane (nil = not offered).
    var onRetry: (() -> Void)? = nil

    /// The one status this tile shows, before the transient-success fade.
    private var baseStatus: TileStatus {
        TileStatus.resolve(status: lane.status,
                           captureOutcome: lane.captureOutcome,
                           isRecording: lane.isRecording,
                           collection: lane.collection,
                           needsQualityRematch: lane.needsQualityRematch)
    }

    /// The status actually rendered: once a success confirmation has faded, the
    /// tile falls back to its resting status (a rematch warning, or nothing).
    private var shownStatus: TileStatus {
        guard baseStatus == .success, successFaded else { return baseStatus }
        return TileStatus.resolve(status: lane.status,
                                  captureOutcome: lane.captureOutcome,
                                  isRecording: lane.isRecording,
                                  collection: lane.collection,
                                  needsQualityRematch: lane.needsQualityRematch,
                                  includeSuccess: false)
    }

    @State private var successFaded = false

    var body: some View {
        ZStack {
            LiveFrameView(frames: lane.frames, aspectRatio: aspectRatio,
                          mirroredHorizontally: mirroredHorizontally,
                          mirroredVertically: mirroredVertically)
                .clipShape(RoundedRectangle(cornerRadius: isThumbnail ? 10 : 0))
                .saturation(lane.status == .linked ? 1 : 0)

            // Reconnecting is the one full-tile treatment; every other status is
            // the single corner badge, so nothing ever stacks on nothing.
            if shownStatus == .reconnecting {
                RoundedRectangle(cornerRadius: isThumbnail ? 10 : 0)
                    .fill(Color.black.opacity(0.45))
                    .overlay(
                        Text(NSLocalizedString("RECONNECTING", comment: "peer link dropped"))
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.white))
            } else {
                VStack {
                    ZStack {
                        // Per-camera timer, CENTERED on the tile's top edge:
                        // THIS camera's own tick, verbatim — four cameras
                        // show four timers, each driven by its own device.
                        if lane.isRecording {
                            LaneRecordingTimer(elapsedMillis: lane.recordingElapsedMillis,
                                               compact: isThumbnail)
                        }
                        HStack {
                            Spacer()
                            TileStatusBadge(status: shownStatus, onRetry: onRetry,
                                            diameter: isThumbnail ? 22 : 28)
                                .transition(.opacity)
                        }
                    }
                    Spacer()
                }
                .padding(6)
            }

            VStack {
                Spacer()
                Text(lane.displayName)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Capsule())
                    .padding(4)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: isThumbnail ? 10 : 0)
                .stroke(lane.isFocused ? AppTheme.accent : .clear, lineWidth: 3))
        // Auto-fade a success confirmation after ~2s; the task restarts (and
        // resets the fade) whenever the underlying status changes.
        .task(id: baseStatus) {
            successFaded = false
            guard baseStatus.isTransient else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeInOut(duration: 0.3)) { successFaded = true }
        }
    }
}

/// Lists the cameras the director's browser has discovered but not yet added,
/// so the user can invite them into the rig mid-session. Shown only below the
/// tier cap (the host routes to the paywall at the cap).
///
/// Currently unpresented: the director screen has no add-camera affordance, so
/// a rig is fixed once the scanner hands it over. The sheet is kept whole —
/// `MulticamViewModel.availablePeers` is still filled — so restoring the
/// entry point is a change to the chrome alone.
struct AddCameraSheet: View {
    let peers: [MCPeerID]
    let onInvite: (MCPeerID) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Group {
                if peers.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(NSLocalizedString("Searching for cameras…",
                                               comment: "add-camera sheet, no peers yet"))
                            .foregroundColor(.secondary)
                    }
                } else {
                    List(peers, id: \.self) { peer in
                        Button { onInvite(peer) } label: {
                            HStack {
                                Image(systemName: "iphone.radiowaves.left.and.right")
                                    .foregroundColor(AppTheme.accent)
                                Text(peer.displayName)
                                Spacer()
                                Text(NSLocalizedString("Add", comment: "invite this camera"))
                                    .foregroundColor(AppTheme.accent)
                            }
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("Add camera",
                                               comment: "add a camera to the multicam rig"))
            // Sheets need an explicit way out on every platform; the
            // cancellation slot also binds Esc and ⌘. on the Mac. A glyph,
            // not text — the bar renders its buttons as circles.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .accessibilityLabel(NSLocalizedString("Cancel", comment: "dismiss the add-camera sheet"))
                }
            }
        }
    }
}

/// The rig settings tray: one self-timer + rig-wide quality (the intersection
/// model). Manual quality selection is first-class; "Automatic" is the reset at
/// the top. Reachable from both focus and grid modes.
/// The rig settings tray, in the 1:1 monitor's glass presentation: a floating
/// panel of tiles that cycle their value in place over the live preview
/// (reusing `MonitorTrayTile`), rather than a pushed table. Timer and quality
/// carry rig semantics — quality cycles the capability intersection, and a
/// footnote names any camera that blocks an option.
struct RigTrayPanel: View {
    let settings: RigSettingsSnapshot
    /// Photo vs video — the tray lists only the tiles that matter to the mode,
    /// exactly as `MonitorTray` does for the 1:1 monitor.
    let mode: MonitorMode
    /// Mid-recording the capture settings dim (standby and help stay live) —
    /// the 1:1 monitor's `configureVideoRecording` rules.
    let isRecording: Bool
    let onSetTimer: (Int) -> Void
    let onSelectVideoQuality: (VideoResolution, VideoFrameRate) -> Void
    let onAutomaticVideoQuality: () -> Void
    let onSetPhotoFormat: (PhotoFormat) -> Void
    let onSetHDR: (Bool) -> Void
    /// Rig aspect ratio picked (one crop across every camera).
    let onSetAspectRatio: (AspectRatio) -> Void
    /// Rig standby: blank (or wake) every supporting camera's own preview.
    let onSetStandby: (Bool) -> Void
    /// Open the app's Settings sheet (purchases, restore, preferences).
    let onOpenSettings: () -> Void
    /// Open the help sheet (the same one every screen presents).
    let onOpenHelp: () -> Void

    private let timerStops = [0, 3, 5, 10, 20]

    var body: some View {
        TrayPanelShell(footnote: settings.blockerFootnote(for: mode)) {
            ForEach(RigTray.items(mode: mode, standbyAvailable: settings.standbyAvailable),
                    id: \.self) { item in
                tile(for: item)
            }
        }
    }

    @ViewBuilder
    private func tile(for item: MonitorTrayItem) -> some View {
        switch item {
        case .timer:
            MonitorTrayTile(item: .timer, value: settings.timerSeconds > 0 ? "\(settings.timerSeconds)" : nil,
                            isActive: settings.timerSeconds > 0, isEnabled: !isRecording,
                            action: cycleTimer)
        case .aspect:
            MonitorTrayTile(item: .aspect, value: settings.aspectRatio.displayName,
                            isActive: false, isEnabled: !isRecording,
                            action: {
                                onSetAspectRatio(MonitorView.cycled(settings.aspectRatio,
                                                                    in: AspectRatio.selectableCases))
                            })
        case .resolution:
            MonitorTrayTile(item: .resolution, value: settings.videoTileValue,
                            isActive: settings.activeVideo != nil,
                            isEnabled: !isRecording && !settings.videoOptions.filter(\.enabled).isEmpty,
                            action: cycleQuality)
        case .format:
            MonitorTrayTile(item: .format, value: (settings.activePhotoFormat ?? .jpeg).displayName,
                            isActive: settings.activePhotoFormat == .heif,
                            isEnabled: !isRecording && settings.heifAvailable,
                            action: { onSetPhotoFormat(settings.activePhotoFormat == .heif ? .jpeg : .heif) })
        case .hdr:
            MonitorTrayTile(item: .hdr, value: nil,
                            isActive: settings.activeHDR == .on,
                            isEnabled: !isRecording && settings.hdrAvailable,
                            action: { onSetHDR(settings.activeHDR != .on) })
        case .cameraStandby:
            MonitorTrayTile(item: .cameraStandby, value: nil,
                            isActive: settings.standbyOn,
                            isEnabled: true,
                            action: { onSetStandby(!settings.standbyOn) })
        case .settings:
            MonitorTrayTile(item: .settings, value: nil,
                            isActive: false, isEnabled: !isRecording,
                            action: onOpenSettings)
        case .help:
            MonitorTrayTile(item: .help, value: nil,
                            isActive: false, isEnabled: true,
                            action: onOpenHelp)
        case .frameRate:
            // Not offered by `RigTray.items` — frame rate rides the single
            // quality tile's intersection cycle.
            EmptyView()
        }
    }

    private func cycleTimer() {
        let idx = timerStops.firstIndex(of: settings.timerSeconds) ?? 0
        onSetTimer(timerStops[(idx + 1) % timerStops.count])
    }

    private func cycleQuality() {
        if let next = settings.nextVideoSelection {
            onSelectVideoQuality(next.resolution, next.frameRate)
        } else {
            onAutomaticVideoQuality()
        }
    }
}
