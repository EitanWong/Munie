#if os(iOS)
  import AVFoundation
  import SwiftUI
  import VisionKit

  struct PairingQRScanner: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var ready = false
    @State private var unavailable = false
    let receive: (String) -> Void

    var body: some View {
      NavigationStack {
        Group {
          if ready {
            PairingScannerCamera(receive: receive) {
              unavailable = true
              ready = false
            }
            .ignoresSafeArea(edges: .bottom)
          } else if unavailable {
            ContentUnavailableView(
              remoteString("Camera scanning unavailable"), systemImage: "qrcode.viewfinder",
              description: Text(
                remoteString(
                  "You can paste the pairing invitation instead. Camera access is optional.")))
          } else {
            ProgressView(remoteString("Preparing camera…"))
          }
        }
        .navigationTitle(remoteString("Scan Mac invitation"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button(remoteString("Close")) { dismiss() } }
        .task {
          guard DataScannerViewController.isSupported else {
            unavailable = true
            return
          }
          let allowed = await AVCaptureDevice.requestAccess(for: .video)
          guard !Task.isCancelled else { return }
          ready = allowed && DataScannerViewController.isAvailable
          unavailable = !ready
        }
        .onChange(of: scenePhase) { _, phase in
          if phase == .background || (phase == .inactive && ready) { dismiss() }
        }
      }
    }
  }

  private struct PairingScannerCamera: UIViewControllerRepresentable {
    let receive: (String) -> Void
    let unavailable: () -> Void

    func makeUIViewController(context: Context) -> PairingScannerController {
      PairingScannerController(receive: receive, unavailable: unavailable)
    }

    func updateUIViewController(_ controller: PairingScannerController, context: Context) {}

    static func dismantleUIViewController(_ controller: PairingScannerController, coordinator: ()) {
      controller.stop()
    }
  }

  private final class PairingScannerController: UIViewController, DataScannerViewControllerDelegate
  {
    private let scanner = DataScannerViewController(
      recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
      recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
      isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
    private let receive: (String) -> Void
    private let unavailable: () -> Void
    private var received = false

    init(receive: @escaping (String) -> Void, unavailable: @escaping () -> Void) {
      self.receive = receive
      self.unavailable = unavailable
      super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
      super.viewDidLoad()
      scanner.delegate = self
      addChild(scanner)
      view.addSubview(scanner.view)
      scanner.view.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        scanner.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        scanner.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        scanner.view.topAnchor.constraint(equalTo: view.topAnchor),
        scanner.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      ])
      scanner.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      do { try scanner.startScanning() } catch { unavailable() }
    }

    override func viewWillDisappear(_ animated: Bool) {
      stop()
      super.viewWillDisappear(animated)
    }

    func stop() { scanner.stopScanning() }

    func dataScanner(
      _ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
      allItems: [RecognizedItem]
    ) {
      guard !received else { return }
      for case .barcode(let code) in addedItems {
        if let payload = code.payloadStringValue, payload.utf8.count <= 16_384 {
          received = true
          stop()
          receive(payload)
          return
        }
      }
    }

    func dataScanner(
      _ dataScanner: DataScannerViewController,
      becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
    ) {
      stop()
      unavailable()
    }
  }
#endif
