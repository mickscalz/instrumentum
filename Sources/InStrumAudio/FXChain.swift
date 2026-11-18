import AVFoundation
import AudioToolbox
import InStrumCore
import os

/// The effects and tone after the instrument (the DDJ-ERGO's knobs): drive → crush → tone and filter → echo → reverb,
/// all Apple's own units, none of which adds latency. Every unit that has nothing to do is bypassed, so a neutral
/// `SoundFX` passes the instrument through untouched.
///
/// `apply` may be called from any thread (the CoreMIDI thread turns the knobs; the panel's sliders are on the main
/// thread): it only sets unit parameters, under a lock so two callers never interleave. The engine owns attaching and
/// connecting the nodes, on the main thread.
final class FXChain {
    let drive = AVAudioUnitDistortion()
    let crush = AVAudioUnitDistortion()
    /// Bands 0…2 are the tone (low shelf, mid bell, high shelf); 3 is the filter's low-pass, 4 its high-pass.
    let tone = AVAudioUnitEQ(numberOfBands: 5)
    let echo = AVAudioUnitDelay()
    let reverb = AVAudioUnitReverb()

    /// In signal order.
    var nodes: [AVAudioNode] { [drive, crush, tone, echo, reverb] }
    /// Where the instrument plugs in.
    var input: AVAudioNode { drive }

    private let lock = OSAllocatedUnfairLock(uncheckedState: SoundFX())
    private var configured = false

    /// The settings last applied (tests).
    var current: SoundFX { lock.withLockUnchecked { $0 } }

    /// The fixed part of every unit; once, before the first `apply`.
    private func configure() {
        configured = true
        // The two distortion units each do one thing: every other stage inside them is mixed out.
        for unit in [drive, crush] {
            set(unit, kDistortionParam_DelayMix, 0)
            set(unit, kDistortionParam_RingModMix, 0)
            set(unit, kDistortionParam_PolynomialMix, 0)
            set(unit, kDistortionParam_DecimationMix, 0)
            set(unit, kDistortionParam_FinalMix, 0)
            unit.bypass = true
        }
        set(crush, kDistortionParam_DecimationMix, 100)
        set(crush, kDistortionParam_SoftClipGain, -6)
        set(crush, kDistortionParam_Rounding, 0)

        let bands = tone.bands
        bands[0].filterType = .lowShelf; bands[0].frequency = 180
        bands[1].filterType = .parametric; bands[1].frequency = 1_000; bands[1].bandwidth = 1.4
        bands[2].filterType = .highShelf; bands[2].frequency = 4_500
        bands[3].filterType = .resonantLowPass; bands[3].frequency = 18_000; bands[3].bandwidth = 0.7
        bands[4].filterType = .resonantHighPass; bands[4].frequency = 30; bands[4].bandwidth = 0.7
        for band in bands { band.gain = 0; band.bypass = true }
        tone.globalGain = 0
        tone.bypass = true

        echo.lowPassCutoff = 6_000     // each repeat a little darker, so the echo sits behind the playing
        echo.wetDryMix = 0
        echo.bypass = true
        reverb.loadFactoryPreset(.largeHall)
        reverb.wetDryMix = 0
        reverb.bypass = true
    }

    private func set(_ unit: AVAudioUnit, _ parameter: AudioUnitParameterID, _ value: Float) {
        AudioUnitSetParameter(unit.audioUnit, parameter, kAudioUnitScope_Global, 0, value, 0)
    }

    func apply(_ fx: SoundFX) {
        lock.withLockUnchecked { stored in
            if !configured { configure() }
            stored = fx

            let driveAmount = fx.effective(.drive)
            let driving = driveAmount >= FXMath.silent
            if driving {
                set(drive, kDistortionParam_SoftClipGain, Float(FXMath.driveGainDB(driveAmount)))
                set(drive, kDistortionParam_FinalMix, Float(FXMath.driveMixPercent(driveAmount)))
            }
            drive.bypass = !driving

            let crushAmount = fx.effective(.crush)
            let crushing = crushAmount >= FXMath.silent
            if crushing {
                set(crush, kDistortionParam_Decimation, Float(FXMath.crushDecimationPercent(crushAmount)))
                set(crush, kDistortionParam_FinalMix, Float(FXMath.crushMixPercent(crushAmount)))
            }
            crush.bypass = !crushing

            let bands = tone.bands
            let gains = [FXMath.eqGainDB(fx.effective(.eqLow)), FXMath.eqGainDB(fx.effective(.eqMid)),
                         FXMath.eqGainDB(fx.effective(.eqHigh))]
            var toneInUse = false
            for (i, gain) in gains.enumerated() {
                bands[i].gain = Float(gain)
                bands[i].bypass = gain == 0
                if gain != 0 { toneInUse = true }
            }
            switch FXMath.filter(fx.effective(.filter)) {
            case .off:
                bands[3].bypass = true; bands[4].bypass = true
            case let .lowPass(hz):
                bands[3].frequency = Float(hz); bands[3].bypass = false; bands[4].bypass = true
                toneInUse = true
            case let .highPass(hz):
                bands[4].frequency = Float(hz); bands[4].bypass = false; bands[3].bypass = true
                toneInUse = true
            }
            let makeup = driving ? FXMath.driveMakeupDB(driveAmount) : 0
            tone.globalGain = Float(makeup)
            tone.bypass = !toneInUse && makeup == 0

            let echoAmount = fx.effective(.echo)
            let echoing = echoAmount >= FXMath.silent
            if echoing {
                echo.delayTime = FXMath.echoSeconds(fx.effective(.echoTime))
                echo.feedback = Float(FXMath.echoFeedbackPercent(fx.effective(.echoRepeats)))
            }
            echo.wetDryMix = Float(FXMath.echoMixPercent(echoAmount))
            echo.bypass = !echoing

            let reverbAmount = fx.effective(.reverb)
            reverb.wetDryMix = Float(FXMath.reverbMixPercent(reverbAmount))
            reverb.bypass = reverbAmount < FXMath.silent
        }
    }

    /// Joins the units in order and the last to `destination`.
    func connect(in engine: AVAudioEngine, to destination: AVAudioNode, format: AVAudioFormat) {
        let chain = nodes
        for i in 0..<chain.count {
            let next = i + 1 < chain.count ? chain[i + 1] : destination
            engine.connect(chain[i], to: next, format: format)
        }
    }
}
