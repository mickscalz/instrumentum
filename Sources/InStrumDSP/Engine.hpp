// The interface every built-in instrument engine implements. All calls happen on the render thread.
#pragma once

namespace isd {

class Engine {
public:
    virtual ~Engine() = default;
    /// `snap` jumps straight to the value (used before the first render).
    virtual void setParam(int address, float value, bool snap) = 0;
    virtual void noteOn(int note, int velocity) = 0;
    virtual void noteOff(int note) = 0;
    virtual void setSustain(bool down) = 0;
    /// Every note fades out over 20 ms; the reverb tail continues.
    virtual void allNotesOff() = 0;
    /// As allNotesOff, and the reverb is cleared.
    virtual void allSoundOff() = 0;
    /// Overwrites the buffers.
    virtual void render(float *left, float *right, int frames) = 0;
    virtual int activeVoices() const = 0;
    /// Internal counters for tests (see ISDDebugCount); engines without one return 0.
    virtual int debugCount(int which) const { (void)which; return 0; }
    /// The pitch wheel, in semitones (−2…+2, 0 at rest). Engines that don't bend ignore it.
    virtual void pitchBend(float semitones) { (void)semitones; }
    /// Aftertouch 0…1: `note` −1 is channel pressure (every held note), otherwise poly pressure on that note.
    /// Engines that don't respond to pressure ignore it.
    virtual void aftertouch(int note, float pressure) { (void)note; (void)pressure; }
    /// A continuous controller, 0…1 (CC 1, the mod wheel, so far). Engines that don't use it ignore it.
    virtual void controller(int cc, float value) { (void)cc; (void)value; }
    /// Any thread, unlike everything above (Endless Rise): the tension 0…1 from the world. The engine keeps it in an
    /// atomic and reads it once per control block. Engines without a riser ignore it.
    virtual void setTension(float tension) { (void)tension; }
    /// Any thread (Endless Rise): the drop. The engine counts it in an atomic and takes it at its next control block.
    virtual void triggerDrop() {}
};

} // namespace isd
