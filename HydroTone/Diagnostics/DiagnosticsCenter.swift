import Foundation
import Observation
import MetricKit

@MainActor @Observable
final class DiagnosticsCenter {
    let recorder: DiagnosticRecorder
    private let metrics: MetricSubscriber
    init() {
        recorder = DiagnosticRecorder()
        metrics = MetricSubscriber(recorder: recorder)
    }
}

// MXMetricManager supports the iOS 26 minimum; the newer MetricManager requires iOS 27.
private final class MetricSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let recorder: DiagnosticRecorder
    init(recorder: DiagnosticRecorder) {
        self.recorder = recorder
        super.init()
        MXMetricManager.shared.add(self)
    }
    deinit { MXMetricManager.shared.remove(self) }
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads { let data = payload.jsonRepresentation(); Task { await recorder.receiveMetricKit(data, type: "metric") } }
    }
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { let data = payload.jsonRepresentation(); Task { await recorder.receiveMetricKit(data, type: "diagnostic") } }
    }
}
