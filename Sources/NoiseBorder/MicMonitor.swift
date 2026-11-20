import AVFoundation
import CoreAudio
import NoiseKit

/// Слушает микрофон и раз в 0.1 с отдаёт мощность в речевой полосе и признак голоса. Звук не записывается и никуда не уходит:
/// из каждого буфера считается только средний уровень.
/// Берёт встроенный микрофон Mac, если он есть: микрофон Bluetooth-наушников переключил бы их в режим гарнитуры.
@MainActor
final class MicMonitor {
    enum Failure: Error { case denied, noInput, engine(String) }

    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var onFrame: ((LevelMeter.Frame, Double) -> Void)?
    private var lastRestart = Date.distantPast

    var isRunning: Bool { engine != nil }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// - Parameter onFrame: (кадр: мощность и признак голоса, длина кадра в секундах), вызывается на главном потоке.
    func start(onFrame: @escaping (LevelMeter.Frame, Double) -> Void) throws {
        stop()
        self.onFrame = onFrame
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if var id = Self.builtInInputDevice(), let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }

        let box = MeterBox(LevelMeter(sampleRate: format.sampleRate))
        let frameSeconds = box.meter.frameSeconds
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let ch = buffer.floatChannelData?[0] else { return }
            let frames = box.meter.process(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
            guard !frames.isEmpty else { return }
            Task { @MainActor in
                for p in frames { self?.onFrame?(p, frameSeconds) }
            }
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw Failure.engine(error.localizedDescription)
        }
        self.engine = engine
        // Смена устройства ввода или его формата останавливает движок: перезапускаемся.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Не чаще раза в 2 с: защита от цикла перезапусков, если смена конфигурации повторяется.
                guard let self, let handler = self.onFrame, Date().timeIntervalSince(self.lastRestart) > 2 else { return }
                self.lastRestart = Date()
                try? self.start(onFrame: handler)
            }
        }
    }

    func stop() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    /// Встроенный микрофон Mac (транспорт BuiltIn с входными потоками), nil если его нет.
    private static func builtInInputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { id in
            var transport: UInt32 = 0
            var tsize = UInt32(MemoryLayout<UInt32>.size)
            var taddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &taddr, 0, nil, &tsize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { return false }
            var saddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                   mScope: kAudioObjectPropertyScopeInput,
                                                   mElement: kAudioObjectPropertyElementMain)
            var ssize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &saddr, 0, nil, &ssize) == noErr && ssize > 0
        }
    }
}

/// Состояние измерителя живёт в аудиопотоке tap-блока.
private final class MeterBox: @unchecked Sendable {
    var meter: LevelMeter
    init(_ meter: LevelMeter) { self.meter = meter }
}
