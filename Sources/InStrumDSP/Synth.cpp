// C interface for the built-in instruments: engine dispatch, parameters, sample-accurate MIDI.
#include "include/InStrumDSP.h"
#include "Engine.hpp"
#include "FeltGlass.hpp"
#include "OrbitPad.hpp"
#include "HoneyTape.hpp"
#include "HazeBells.hpp"
#include "CabinFelt.hpp"
#include "MorningBox.hpp"
#include "PolarChoir.hpp"
#include "PlanktonKeys.hpp"
#include "TeaHouseKoto.hpp"
#include "ZenShakuhachi.hpp"
#include "ReefMarimba.hpp"
#include "BlueDepth.hpp"
#include "MagmaBass.hpp"
#include "ReplicantBrass.hpp"
#include "EndlessRise.hpp"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <memory>

namespace {

const ISDParamInfo kFeltGlassParams[] = {
    {ISD_P_FINE_TUNE, "fineTune", "Fine tune", -50.f, 50.f, 0.f, 1},
    {ISD_P_TRANSPOSE, "transpose", "Transpose", -12.f, 12.f, 0.f, 2},
    {ISD_P_SPACE, "space", "Space", 0.f, 1.f, 0.45f, 0},
    {ISD_P_FELT, "felt", "Felt", 0.f, 1.f, 0.55f, 0},
    {ISD_P_GLASS, "glass", "Glass", 0.f, 1.f, 0.35f, 0},
    {ISD_P_WARMTH, "warmth", "Warmth", 0.f, 1.f, 0.60f, 0},
    {ISD_P_RING, "ring", "Ring", 0.f, 1.f, 0.55f, 0},
    {ISD_P_WIDTH, "width", "Width", 0.f, 1.f, 0.50f, 0},
    {ISD_P_MOOD_ENERGY, "moodEnergy", "Mood energy", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_WARMTH, "moodWarmth", "Mood warmth", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_BRIGHTNESS, "moodBrightness", "Mood brightness", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_SPACE, "moodSpace", "Mood space", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_MOTION, "moodMotion", "Mood motion", 0.f, 1.f, 0.5f, 0},
};

const ISDParamInfo kOrbitPadParams[] = {
    {ISD_P_FINE_TUNE, "fineTune", "Fine tune", -50.f, 50.f, 0.f, 1},
    {ISD_P_TRANSPOSE, "transpose", "Transpose", -12.f, 12.f, 0.f, 2},
    {ISD_P_SPACE, "space", "Space", 0.f, 1.f, 0.55f, 0},
    {ISD_P_BLOOM, "bloom", "Bloom", 0.f, 1.f, 0.55f, 0},
    {ISD_P_DRIFT, "drift", "Drift", 0.f, 1.f, 0.40f, 0},
    {ISD_P_MOTION, "motion", "Motion", 0.f, 1.f, 0.45f, 0},
    {ISD_P_SHIMMER, "shimmer", "Shimmer", 0.f, 1.f, 0.25f, 0},
    {ISD_P_BRIGHTNESS, "brightness", "Brightness", 0.f, 1.f, 0.50f, 0},
    {ISD_P_MOOD_ENERGY, "moodEnergy", "Mood energy", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_WARMTH, "moodWarmth", "Mood warmth", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_BRIGHTNESS, "moodBrightness", "Mood brightness", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_SPACE, "moodSpace", "Mood space", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_MOTION, "moodMotion", "Mood motion", 0.f, 1.f, 0.5f, 0},
    {ISD_P_DEBUG_LAYER_A_ONLY, "debugLayerAOnly", "Layer A only (test)", 0.f, 1.f, 0.f, 3},
};

const ISDParamInfo kHoneyTapeParams[] = {
    {ISD_P_FINE_TUNE, "fineTune", "Fine tune", -50.f, 50.f, 0.f, 1},
    {ISD_P_TRANSPOSE, "transpose", "Transpose", -12.f, 12.f, 0.f, 2},
    {ISD_P_BREATH, "breath", "Breath", 0.f, 1.f, 0.45f, 0},
    {ISD_P_STRINGS, "strings", "Strings", 0.f, 1.f, 0.30f, 0},
    {ISD_P_WOW, "wow", "Wow", 0.f, 1.f, 0.35f, 0},
    {ISD_P_AGE, "age", "Age", 0.f, 1.f, 0.40f, 0},
    {ISD_P_REEL, "reel", "Reel", 0.f, 1.f, 0.f, 0},
    {ISD_P_SPACE, "space", "Space", 0.f, 1.f, 0.50f, 0},
    {ISD_P_WIDTH, "width", "Width", 0.f, 1.f, 0.50f, 0},
    {ISD_P_MOOD_ENERGY, "moodEnergy", "Mood energy", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_WARMTH, "moodWarmth", "Mood warmth", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_BRIGHTNESS, "moodBrightness", "Mood brightness", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_SPACE, "moodSpace", "Mood space", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_MOTION, "moodMotion", "Mood motion", 0.f, 1.f, 0.5f, 0},
    {ISD_P_DEBUG_NO_VIBRATO, "debugNoVibrato", "No vibrato (test)", 0.f, 1.f, 0.f, 3},
};

const ISDParamInfo kHazeBellsParams[] = {
    {ISD_P_FINE_TUNE, "fineTune", "Fine tune", -50.f, 50.f, 0.f, 1},
    {ISD_P_TRANSPOSE, "transpose", "Transpose", -12.f, 12.f, 0.f, 2},
    {ISD_P_BELLS, "bells", "Bells", 0.f, 1.f, 0.80f, 0},
    {ISD_P_ORGAN, "organ", "Organ", 0.f, 1.f, 0.25f, 0},
    {ISD_P_ECHO, "echo", "Echo", 0.f, 1.f, 0.35f, 0},
    {ISD_P_CRUSH, "crush", "Crush", 0.f, 1.f, 0.15f, 0},
    {ISD_P_DRIFT, "drift", "Drift", 0.f, 1.f, 0.30f, 0},
    {ISD_P_SPACE, "space", "Space", 0.f, 1.f, 0.50f, 0},
    {ISD_P_MOOD_ENERGY, "moodEnergy", "Mood energy", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_WARMTH, "moodWarmth", "Mood warmth", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_BRIGHTNESS, "moodBrightness", "Mood brightness", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_SPACE, "moodSpace", "Mood space", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_MOTION, "moodMotion", "Mood motion", 0.f, 1.f, 0.5f, 0},
};

const ISDParamInfo kCabinFeltParams[] = {
    {ISD_P_FINE_TUNE, "fineTune", "Fine tune", -50.f, 50.f, 0.f, 1},
    {ISD_P_TRANSPOSE, "transpose", "Transpose", -12.f, 12.f, 0.f, 2},
    {ISD_P_FELT, "felt", "Felt", 0.f, 1.f, 0.60f, 0},
    {ISD_P_HORN, "horn", "Horn", 0.f, 1.f, 0.30f, 0},
    {ISD_P_FIRE, "fire", "Fire", 0.f, 1.f, 0.50f, 0},
    {ISD_P_WOOD, "wood", "Wood", 0.f, 1.f, 0.50f, 0},
    {ISD_P_SPACE, "space", "Space", 0.f, 1.f, 0.35f, 0},
    {ISD_P_WIDTH, "width", "Width", 0.f, 1.f, 0.50f, 0},
    {ISD_P_MOOD_ENERGY, "moodEnergy", "Mood energy", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_WARMTH, "moodWarmth", "Mood warmth", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_BRIGHTNESS, "moodBrightness", "Mood brightness", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_SPACE, "moodSpace", "Mood space", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_MOTION, "moodMotion", "Mood motion", 0.f, 1.f, 0.5f, 0},
    {ISD_P_DEBUG_NO_MECHANICS, "debugNoMechanics", "No mechanics (test)", 0.f, 1.f, 0.f, 3},
    {ISD_P_DEBUG_HORN_ONLY, "debugHornOnly", "Horn only (test)", 0.f, 1.f, 0.f, 3},
};

const ISDParamInfo kMorningBoxParams[] = {
    {ISD_P_FINE_TUNE, "fineTune", "Fine tune", -50.f, 50.f, 0.f, 1},
    {ISD_P_TRANSPOSE, "transpose", "Transpose", -12.f, 12.f, 0.f, 2},
    {ISD_P_BARS, "bars", "Bars", 0.f, 1.f, 0.60f, 0},
    {ISD_P_BOX, "box", "Box", 0.f, 1.f, 0.20f, 0},
    {ISD_P_BLOOM, "bloom", "Bloom", 0.f, 1.f, 0.40f, 0},
    {ISD_P_BUILD, "build", "Build", 0.f, 1.f, 0.50f, 0},
    {ISD_P_HAZE, "haze", "Haze", 0.f, 1.f, 0.35f, 0},
    {ISD_P_SPACE, "space", "Space", 0.f, 1.f, 0.50f, 0},
    {ISD_P_WIDTH, "width", "Width", 0.f, 1.f, 0.55f, 0},
    {ISD_P_MOOD_ENERGY, "moodEnergy", "Mood energy", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_WARMTH, "moodWarmth", "Mood warmth", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_BRIGHTNESS, "moodBrightness", "Mood brightness", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_SPACE, "moodSpace", "Mood space", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_MOTION, "moodMotion", "Mood motion", 0.f, 1.f, 0.5f, 0},
    {ISD_P_DEBUG_BOX_ONLY, "debugBoxOnly", "Box only (test)", 0.f, 1.f, 0.f, 3},
    {ISD_P_DEBUG_WALL_ONLY, "debugWallOnly", "Wall only (test)", 0.f, 1.f, 0.f, 3},
};

const ISDParamInfo kPolarChoirParams[] = {
    {ISD_P_FINE_TUNE, "fineTune", "Fine tune", -50.f, 50.f, 0.f, 1},
    {ISD_P_TRANSPOSE, "transpose", "Transpose", -12.f, 12.f, 0.f, 2},
    {ISD_P_VOWEL, "vowel", "Vowel", 0.f, 1.f, 0.55f, 0},
    {ISD_P_BREATH, "breath", "Breath", 0.f, 1.f, 0.35f, 0},
    {ISD_P_GLASS, "glass", "Glass", 0.f, 1.f, 0.30f, 0},
    {ISD_P_SWELL, "swell", "Swell", 0.f, 1.f, 0.55f, 0},
    {ISD_P_SHIMMER, "shimmer", "Shimmer", 0.f, 1.f, 0.25f, 0},
    {ISD_P_SPACE, "space", "Space", 0.f, 1.f, 0.60f, 0},
    {ISD_P_WIDTH, "width", "Width", 0.f, 1.f, 0.60f, 0},
    {ISD_P_MOOD_ENERGY, "moodEnergy", "Mood energy", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_WARMTH, "moodWarmth", "Mood warmth", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_BRIGHTNESS, "moodBrightness", "Mood brightness", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_SPACE, "moodSpace", "Mood space", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_MOTION, "moodMotion", "Mood motion", 0.f, 1.f, 0.5f, 0},
    {ISD_P_DEBUG_VOICES_ONLY, "debugVoicesOnly", "Voices only (test)", 0.f, 1.f, 0.f, 3},
};

const ISDParamInfo kPlanktonKeysParams[] = {
    {ISD_P_FINE_TUNE, "fineTune", "Fine tune", -50.f, 50.f, 0.f, 1},
    {ISD_P_TRANSPOSE, "transpose", "Transpose", -12.f, 12.f, 0.f, 2},
    {ISD_P_TINE, "tine", "Tine", 0.f, 1.f, 0.55f, 0},
    {ISD_P_BARK, "bark", "Bark", 0.f, 1.f, 0.40f, 0},
    {ISD_P_SPARKLE, "sparkle", "Sparkle", 0.f, 1.f, 0.50f, 0},
    {ISD_P_TREMOLO, "tremolo", "Tremolo", 0.f, 1.f, 0.35f, 0},
    {ISD_P_PHASE, "phase", "Phase", 0.f, 1.f, 0.20f, 0},
    {ISD_P_SPACE, "space", "Space", 0.f, 1.f, 0.50f, 0},
    {ISD_P_WIDTH, "width", "Width", 0.f, 1.f, 0.55f, 0},
    {ISD_P_MOOD_ENERGY, "moodEnergy", "Mood energy", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_WARMTH, "moodWarmth", "Mood warmth", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_BRIGHTNESS, "moodBrightness", "Mood brightness", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_SPACE, "moodSpace", "Mood space", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_MOTION, "moodMotion", "Mood motion", 0.f, 1.f, 0.5f, 0},
    {ISD_P_DEBUG_NO_SPARKLE, "debugNoSparkle", "No sparkle (test)", 0.f, 1.f, 0.f, 3},
    {ISD_P_DEBUG_NO_TREMOLO, "debugNoTremolo", "No tremolo (test)", 0.f, 1.f, 0.f, 3},
};

const ISDParamInfo kTeaHouseKotoParams[] = {
    {ISD_P_FINE_TUNE, "fineTune", "Fine tune", -50.f, 50.f, 0.f, 1},
    {ISD_P_TRANSPOSE, "transpose", "Transpose", -12.f, 12.f, 0.f, 2},
    {ISD_P_PICK, "pick", "Pick", 0.f, 1.f, 0.55f, 0},
    {ISD_P_SILK, "silk", "Silk", 0.f, 1.f, 0.45f, 0},
    {ISD_P_BODY, "body", "Body", 0.f, 1.f, 0.50f, 0},
    {ISD_P_BLOOM, "bloom", "Bloom", 0.f, 1.f, 0.40f, 0},
    {ISD_P_YURI, "yuri", "Yuri", 0.f, 1.f, 0.30f, 0},
    {ISD_P_SPACE, "space", "Space", 0.f, 1.f, 0.35f, 0},
    {ISD_P_WIDTH, "width", "Width", 0.f, 1.f, 0.50f, 0},
    {ISD_P_MOOD_ENERGY, "moodEnergy", "Mood energy", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_WARMTH, "moodWarmth", "Mood warmth", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_BRIGHTNESS, "moodBrightness", "Mood brightness", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_SPACE, "moodSpace", "Mood space", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_MOTION, "moodMotion", "Mood motion", 0.f, 1.f, 0.5f, 0},
    {ISD_P_DEBUG_NO_SYMPATHY, "debugNoSympathy", "No sympathy (test)", 0.f, 1.f, 0.f, 3},
    {ISD_P_DEBUG_NO_BODY, "debugNoBody", "No body (test)", 0.f, 1.f, 0.f, 3},
};

const ISDParamInfo kZenShakuhachiParams[] = {
    {ISD_P_FINE_TUNE, "fineTune", "Fine tune", -50.f, 50.f, 0.f, 1},
    {ISD_P_TRANSPOSE, "transpose", "Transpose", -12.f, 12.f, 0.f, 2},
    {ISD_P_BREATH, "breath", "Breath", 0.f, 1.f, 0.45f, 0},
    {ISD_P_AIR, "air", "Air", 0.f, 1.f, 0.55f, 0},
    {ISD_P_BEND, "bend", "Bend", 0.f, 1.f, 0.60f, 0},
    {ISD_P_BAMBOO, "bamboo", "Bamboo", 0.f, 1.f, 0.50f, 0},
    {ISD_P_YURI, "yuri", "Yuri", 0.f, 1.f, 0.40f, 0},
    {ISD_P_ECHO, "echo", "Echo", 0.f, 1.f, 0.30f, 0},
    {ISD_P_SPACE, "space", "Space", 0.f, 1.f, 0.40f, 0},
    {ISD_P_WIDTH, "width", "Width", 0.f, 1.f, 0.45f, 0},
    {ISD_P_MOOD_ENERGY, "moodEnergy", "Mood energy", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_WARMTH, "moodWarmth", "Mood warmth", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_BRIGHTNESS, "moodBrightness", "Mood brightness", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_SPACE, "moodSpace", "Mood space", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_MOTION, "moodMotion", "Mood motion", 0.f, 1.f, 0.5f, 0},
    {ISD_P_DEBUG_TONE_ONLY, "debugToneOnly", "Tone only (test)", 0.f, 1.f, 0.f, 3},
    {ISD_P_DEBUG_NO_FOLD, "debugNoFold", "No octave fold (test)", 0.f, 1.f, 0.f, 3},
};

const ISDParamInfo kReefMarimbaParams[] = {
    {ISD_P_FINE_TUNE, "fineTune", "Fine tune", -50.f, 50.f, 0.f, 1},
    {ISD_P_TRANSPOSE, "transpose", "Transpose", -12.f, 12.f, 0.f, 2},
    {ISD_P_MALLET, "mallet", "Mallet", 0.f, 1.f, 0.45f, 0},
    {ISD_P_STRIKE, "strike", "Strike", 0.f, 1.f, 0.40f, 0},
    {ISD_P_TUBE, "tube", "Tube", 0.f, 1.f, 0.70f, 0},
    {ISD_P_ROLL, "roll", "Roll", 0.f, 1.f, 0.35f, 0},
    {ISD_P_STEEL, "steel", "Steel", 0.f, 1.f, 0.20f, 0},
    {ISD_P_SPACE, "space", "Space", 0.f, 1.f, 0.35f, 0},
    {ISD_P_WIDTH, "width", "Width", 0.f, 1.f, 0.55f, 0},
    {ISD_P_MOOD_ENERGY, "moodEnergy", "Mood energy", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_WARMTH, "moodWarmth", "Mood warmth", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_BRIGHTNESS, "moodBrightness", "Mood brightness", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_SPACE, "moodSpace", "Mood space", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_MOTION, "moodMotion", "Mood motion", 0.f, 1.f, 0.5f, 0},
    {ISD_P_DEBUG_NO_ROLL, "debugNoRoll", "No roll (test)", 0.f, 1.f, 0.f, 3},
    {ISD_P_DEBUG_BAR_ONLY, "debugBarOnly", "Bar only (test)", 0.f, 1.f, 0.f, 3},
};

/// Tempo is in BPM (unit 0 with its own range): it sets both the arp's sixteenths and the dotted-eighth echo.
const ISDParamInfo kBlueDepthParams[] = {
    {ISD_P_FINE_TUNE, "fineTune", "Fine tune", -50.f, 50.f, 0.f, 1},
    {ISD_P_TRANSPOSE, "transpose", "Transpose", -12.f, 12.f, 0.f, 2},
    {ISD_P_BLINK, "blink", "Blink", 0.f, 1.f, 0.60f, 0},
    {ISD_P_MURK, "murk", "Murk", 0.f, 1.f, 0.55f, 0},
    {ISD_P_GHOSTS, "ghosts", "Ghosts", 0.f, 1.f, 0.40f, 0},
    {ISD_P_ECHO, "echo", "Echo", 0.f, 1.f, 0.50f, 0},
    {ISD_P_BASS, "bass", "Bass", 0.f, 1.f, 0.55f, 0},
    {ISD_P_TEMPO, "tempo", "Tempo", 70.f, 160.f, 118.f, 0},
    {ISD_P_SPACE, "space", "Space", 0.f, 1.f, 0.55f, 0},
    {ISD_P_WIDTH, "width", "Width", 0.f, 1.f, 0.60f, 0},
    {ISD_P_MOOD_ENERGY, "moodEnergy", "Mood energy", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_WARMTH, "moodWarmth", "Mood warmth", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_BRIGHTNESS, "moodBrightness", "Mood brightness", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_SPACE, "moodSpace", "Mood space", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_MOTION, "moodMotion", "Mood motion", 0.f, 1.f, 0.5f, 0},
    {ISD_P_DEBUG_NO_ARP, "debugNoArp", "No arp (test)", 0.f, 1.f, 0.f, 3},
    {ISD_P_DEBUG_DRY, "debugDry", "Dry (test)", 0.f, 1.f, 0.f, 3},
};
const ISDParamInfo kMagmaBassParams[] = {
    {ISD_P_FINE_TUNE, "fineTune", "Fine tune", -50.f, 50.f, 0.f, 1},
    {ISD_P_TRANSPOSE, "transpose", "Transpose", -12.f, 12.f, 0.f, 2},
    {ISD_P_GROWL, "growl", "Growl", 0.f, 1.f, 0.55f, 0},
    {ISD_P_HEAT, "heat", "Heat", 0.f, 1.f, 0.50f, 0},
    {ISD_P_ERUPT, "erupt", "Erupt", 0.f, 1.f, 0.70f, 0},
    {ISD_P_RUMBLE, "rumble", "Rumble", 0.f, 1.f, 0.35f, 0},
    {ISD_P_GRIT, "grit", "Grit", 0.f, 1.f, 0.25f, 0},
    {ISD_P_FLOW, "flow", "Flow", 0.f, 1.f, 0.20f, 0},
    {ISD_P_SHAPE, "shape", "Shape", 0.f, 1.f, 0.15f, 0},
    {ISD_P_MONO, "mono", "Mono", 0.f, 1.f, 0.f, 0},
    {ISD_P_SPARK, "spark", "Spark", 0.f, 1.f, 0.40f, 0},
    {ISD_P_RES, "res", "Res", 0.f, 0.9f, 0.35f, 0},
    {ISD_P_SPACE, "space", "Space", 0.f, 1.f, 0.30f, 0},
    {ISD_P_WIDTH, "width", "Width", 0.f, 1.f, 0.40f, 0},
    {ISD_P_MOOD_ENERGY, "moodEnergy", "Mood energy", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_WARMTH, "moodWarmth", "Mood warmth", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_BRIGHTNESS, "moodBrightness", "Mood brightness", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_SPACE, "moodSpace", "Mood space", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_MOTION, "moodMotion", "Mood motion", 0.f, 1.f, 0.5f, 0},
    {ISD_P_DEBUG_MB_DRY, "debugMagmaDry", "Dry (test)", 0.f, 1.f, 0.f, 3},
};
const ISDParamInfo kReplicantBrassParams[] = {
    {ISD_P_FINE_TUNE, "fineTune", "Fine tune", -50.f, 50.f, 0.f, 1},
    {ISD_P_TRANSPOSE, "transpose", "Transpose", -12.f, 12.f, 0.f, 2},
    {ISD_P_SWELL_RB, "swell", "Swell", 0.f, 1.f, 0.60f, 0},
    {ISD_P_BLAZE, "blaze", "Blaze", 0.f, 1.f, 0.50f, 0},
    {ISD_P_UNISON_WIDTH, "width", "Width", 0.f, 1.f, 0.70f, 0},
    {ISD_P_HALL, "hall", "Hall", 0.f, 1.f, 0.55f, 0},
    {ISD_P_CHROME, "chrome", "Chrome", 0.f, 1.f, 0.60f, 0},
    {ISD_P_PUNCH, "punch", "Punch", 0.f, 1.f, 0.50f, 0},
    /* 0 Off, 1 Up, 2 Down, 3 Up-down, 4 Played, 5 Random */
    {ISD_P_ARP_MODE, "arp", "Arp", 0.f, 5.f, 4.f, 0},
    /* 0 1/4, 1 1/8, 2 1/8T, 3 1/16, 4 1/16T, 5 1/32 */
    {ISD_P_ARP_RATE, "rate", "Rate", 0.f, 5.f, 3.f, 0},
    /* below 28: no split; otherwise the split note (E1…C4) */
    {ISD_P_SPLIT, "split", "Split", 0.f, 60.f, 48.f, 0},
    {ISD_P_TEMPO_RB, "tempo", "Tempo", 70.f, 170.f, 120.f, 0},
    {ISD_P_MOOD_ENERGY, "moodEnergy", "Mood energy", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_WARMTH, "moodWarmth", "Mood warmth", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_BRIGHTNESS, "moodBrightness", "Mood brightness", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_SPACE, "moodSpace", "Mood space", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_MOTION, "moodMotion", "Mood motion", 0.f, 1.f, 0.5f, 0},
    {ISD_P_DEBUG_RB_NO_ARP, "debugBrassNoArp", "No arp (test)", 0.f, 1.f, 0.f, 3},
    {ISD_P_DEBUG_RB_DRY, "debugBrassDry", "Dry (test)", 0.f, 1.f, 0.f, 3},
};
/// The dials in the Swift order (Rise, Pressure, Grit, Pulse, Tempo, Tail, Sub, Space, Width). Rise is octaves a second
/// (0 switches the riser off, else 0.02…0.5); Tempo is the Pulse's, in BPM. Defaults are the Supercell preset.
const ISDParamInfo kEndlessRiseParams[] = {
    {ISD_P_FINE_TUNE, "fineTune", "Fine tune", -50.f, 50.f, 0.f, 1},
    {ISD_P_TRANSPOSE, "transpose", "Transpose", -12.f, 12.f, 0.f, 2},
    {ISD_P_RISE, "rise", "Rise", 0.f, 0.5f, 0.08f, 0},
    {ISD_P_PRESSURE, "pressure", "Pressure", 0.f, 1.f, 0.40f, 0},
    {ISD_P_GRIT_ER, "grit", "Grit", 0.f, 1.f, 0.30f, 0},
    {ISD_P_PULSE, "pulse", "Pulse", 0.f, 1.f, 0.50f, 0},
    {ISD_P_TEMPO_ER, "tempo", "Tempo", 70.f, 170.f, 124.f, 0},
    {ISD_P_TAIL, "tail", "Tail", 0.f, 1.f, 0.60f, 0},
    {ISD_P_SUB, "sub", "Sub", 0.f, 1.f, 0.70f, 0},
    {ISD_P_SPACE, "space", "Space", 0.f, 1.f, 0.50f, 0},
    {ISD_P_WIDTH, "width", "Width", 0.f, 1.f, 0.60f, 0},
    {ISD_P_MOOD_ENERGY, "moodEnergy", "Mood energy", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_WARMTH, "moodWarmth", "Mood warmth", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_BRIGHTNESS, "moodBrightness", "Mood brightness", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_SPACE, "moodSpace", "Mood space", 0.f, 1.f, 0.5f, 0},
    {ISD_P_MOOD_MOTION, "moodMotion", "Mood motion", 0.f, 1.f, 0.5f, 0},
    {ISD_P_DEBUG_ER_PAD_ONLY, "debugRisePadOnly", "Pad only (test)", 0.f, 1.f, 0.f, 3},
    {ISD_P_DEBUG_ER_RISE_ONLY, "debugRiseOnly", "Rise only (test)", 0.f, 1.f, 0.f, 3},
    {ISD_P_DEBUG_ER_DRY, "debugRiseDry", "Dry (test)", 0.f, 1.f, 0.f, 3},
};



struct ParamTable { const ISDParamInfo *items; int count; };

ParamTable table(ISDEngine engine) {
    switch (engine) {
    case ISD_ENGINE_FELT_GLASS: return {kFeltGlassParams, (int)(sizeof kFeltGlassParams / sizeof kFeltGlassParams[0])};
    case ISD_ENGINE_ORBIT_PAD: return {kOrbitPadParams, (int)(sizeof kOrbitPadParams / sizeof kOrbitPadParams[0])};
    case ISD_ENGINE_HONEY_TAPE: return {kHoneyTapeParams, (int)(sizeof kHoneyTapeParams / sizeof kHoneyTapeParams[0])};
    case ISD_ENGINE_HAZE_BELLS: return {kHazeBellsParams, (int)(sizeof kHazeBellsParams / sizeof kHazeBellsParams[0])};
    case ISD_ENGINE_CABIN_FELT: return {kCabinFeltParams, (int)(sizeof kCabinFeltParams / sizeof kCabinFeltParams[0])};
    case ISD_ENGINE_MORNING_BOX: return {kMorningBoxParams, (int)(sizeof kMorningBoxParams / sizeof kMorningBoxParams[0])};
    case ISD_ENGINE_POLAR_CHOIR: return {kPolarChoirParams, (int)(sizeof kPolarChoirParams / sizeof kPolarChoirParams[0])};
    case ISD_ENGINE_PLANKTON_KEYS: return {kPlanktonKeysParams, (int)(sizeof kPlanktonKeysParams / sizeof kPlanktonKeysParams[0])};
    case ISD_ENGINE_TEA_HOUSE_KOTO: return {kTeaHouseKotoParams, (int)(sizeof kTeaHouseKotoParams / sizeof kTeaHouseKotoParams[0])};
    case ISD_ENGINE_ZEN_SHAKUHACHI: return {kZenShakuhachiParams, (int)(sizeof kZenShakuhachiParams / sizeof kZenShakuhachiParams[0])};
    case ISD_ENGINE_REEF_MARIMBA: return {kReefMarimbaParams, (int)(sizeof kReefMarimbaParams / sizeof kReefMarimbaParams[0])};
    case ISD_ENGINE_BLUE_DEPTH: return {kBlueDepthParams, (int)(sizeof kBlueDepthParams / sizeof kBlueDepthParams[0])};
    case ISD_ENGINE_MAGMA_BASS: return {kMagmaBassParams, (int)(sizeof kMagmaBassParams / sizeof kMagmaBassParams[0])};
    case ISD_ENGINE_REPLICANT_BRASS: return {kReplicantBrassParams, (int)(sizeof kReplicantBrassParams / sizeof kReplicantBrassParams[0])};
    case ISD_ENGINE_ENDLESS_RISE: return {kEndlessRiseParams, (int)(sizeof kEndlessRiseParams / sizeof kEndlessRiseParams[0])};
    default: return {nullptr, 0};
    }
}

constexpr int kSlots = 256;
constexpr int kMaxEvents = 512;

struct MidiEvent { int offset; int length; uint8_t bytes[3]; };

} // namespace

struct ISDSynth {
    ParamTable params{};
    std::unique_ptr<isd::Engine> engine;
    std::atomic<float> values[kSlots];
    float applied[kSlots];
    MidiEvent events[kMaxEvents];
    int eventCount = 0;
    bool started = false;
    std::atomic<bool> allOff{false};
    std::atomic<int> voices{0};
};

namespace {

void handleMidi(isd::Engine &e, const MidiEvent &m) {
    if (m.length < 1) return;
    const uint8_t status = m.bytes[0] & 0xF0;
    switch (status) {
    case 0x90:
        if (m.length < 3) return;
        if (m.bytes[2] == 0) e.noteOff(m.bytes[1] & 0x7F); else e.noteOn(m.bytes[1] & 0x7F, m.bytes[2] & 0x7F);
        break;
    case 0x80:
        if (m.length >= 2) e.noteOff(m.bytes[1] & 0x7F);
        break;
    case 0xB0:
        if (m.length < 3) return;
        switch (m.bytes[1]) {
        case 1: e.controller(1, (float)(m.bytes[2] & 0x7F) / 127.f); break;   // the mod wheel
        case 64: e.setSustain(m.bytes[2] >= 64); break;
        case 120: e.allSoundOff(); break;
        case 121:   // reset all controllers: the pedal, the wheel, channel and every key's pressure, the mod wheel
            e.setSustain(false); e.pitchBend(0.f); e.aftertouch(-1, 0.f);
            for (int n = 0; n < 128; ++n) e.aftertouch(n, 0.f);   // poly pressure too: no note stays in yuri or meri
            e.controller(1, 0.f);
            break;
        case 123: e.allNotesOff(); break;
        default: break;
        }
        break;
    case 0xE0: {   // pitch wheel: 14 bits, centre 8192, ±2 semitones at the ends
        if (m.length < 3) return;
        const int v = (int)(m.bytes[1] & 0x7F) | ((int)(m.bytes[2] & 0x7F) << 7);
        const int d = v - 8192;
        e.pitchBend(2.f * (float)d / (d >= 0 ? 8191.f : 8192.f));
        break;
    }
    case 0xD0:   // channel pressure
        if (m.length >= 2) e.aftertouch(-1, (float)(m.bytes[1] & 0x7F) / 127.f);
        break;
    case 0xA0:   // poly pressure
        if (m.length >= 3) e.aftertouch(m.bytes[1] & 0x7F, (float)(m.bytes[2] & 0x7F) / 127.f);
        break;
    default:
        break;   // program change, system messages: ignored
    }
}

void applyParams(ISDSynth *s) {
    for (int i = 0; i < s->params.count; ++i) {
        int a = s->params.items[i].address;
        float v = s->values[a].load(std::memory_order_relaxed);
        if (v != s->applied[a] || !s->started) {
            s->engine->setParam(a, v, !s->started);
            s->applied[a] = v;
        }
    }
    s->started = true;
}

} // namespace

extern "C" {

ISDSynth *isd_synth_create(ISDEngine engine, double sampleRate, int maxFrames) {
    (void)maxFrames;
    ParamTable t = table(engine);
    if (t.count == 0 || sampleRate <= 0) return nullptr;
    auto *s = new ISDSynth();
    s->params = t;
    for (int a = 0; a < kSlots; ++a) { s->values[a].store(0.f); s->applied[a] = 0.f; }
    for (int i = 0; i < t.count; ++i) s->values[t.items[i].address].store(t.items[i].defaultValue);
    switch (engine) {
    case ISD_ENGINE_FELT_GLASS: s->engine = std::make_unique<isd::FeltGlass>(sampleRate); break;
    case ISD_ENGINE_ORBIT_PAD: s->engine = std::make_unique<isd::OrbitPad>(sampleRate); break;
    case ISD_ENGINE_HONEY_TAPE: s->engine = std::make_unique<isd::HoneyTape>(sampleRate); break;
    case ISD_ENGINE_HAZE_BELLS: s->engine = std::make_unique<isd::HazeBells>(sampleRate); break;
    case ISD_ENGINE_CABIN_FELT: s->engine = std::make_unique<isd::CabinFelt>(sampleRate); break;
    case ISD_ENGINE_MORNING_BOX: s->engine = std::make_unique<isd::MorningBox>(sampleRate); break;
    case ISD_ENGINE_POLAR_CHOIR: s->engine = std::make_unique<isd::PolarChoir>(sampleRate); break;
    case ISD_ENGINE_PLANKTON_KEYS: s->engine = std::make_unique<isd::PlanktonKeys>(sampleRate); break;
    case ISD_ENGINE_TEA_HOUSE_KOTO: s->engine = std::make_unique<isd::TeaHouseKoto>(sampleRate); break;
    case ISD_ENGINE_ZEN_SHAKUHACHI: s->engine = std::make_unique<isd::ZenShakuhachi>(sampleRate); break;
    case ISD_ENGINE_REEF_MARIMBA: s->engine = std::make_unique<isd::ReefMarimba>(sampleRate); break;
    case ISD_ENGINE_BLUE_DEPTH: s->engine = std::make_unique<isd::BlueDepth>(sampleRate); break;
    case ISD_ENGINE_MAGMA_BASS: s->engine = std::make_unique<isd::MagmaBass>(sampleRate); break;
    case ISD_ENGINE_REPLICANT_BRASS: s->engine = std::make_unique<isd::ReplicantBrass>(sampleRate); break;
    case ISD_ENGINE_ENDLESS_RISE: s->engine = std::make_unique<isd::EndlessRise>(sampleRate); break;
    default: delete s; return nullptr;
    }
    return s;
}

void isd_synth_destroy(ISDSynth *s) { delete s; }

int isd_synth_param_count(ISDEngine engine) { return table(engine).count; }

const ISDParamInfo *isd_synth_param_info(ISDEngine engine, int index) {
    ParamTable t = table(engine);
    return index >= 0 && index < t.count ? &t.items[index] : nullptr;
}

void isd_synth_set_param(ISDSynth *s, int address, float value) {
    if (!s) return;
    for (int i = 0; i < s->params.count; ++i) {
        const ISDParamInfo &p = s->params.items[i];
        if (p.address != address) continue;
        if (!std::isfinite(value)) return;
        float v = std::clamp(value, p.minValue, p.maxValue);
        if (p.unit == 2) v = std::round(v);
        s->values[address].store(v, std::memory_order_relaxed);
        return;
    }
}

float isd_synth_get_param(const ISDSynth *s, int address) {
    if (!s || address < 0 || address >= kSlots) return 0.f;
    return s->values[address].load(std::memory_order_relaxed);
}

void isd_synth_midi(ISDSynth *s, const uint8_t *bytes, int length, int sampleOffset) {
    if (!s || !bytes || length <= 0 || s->eventCount >= kMaxEvents) return;
    MidiEvent &m = s->events[s->eventCount++];
    m.offset = std::max(0, sampleOffset);
    m.length = std::min(length, 3);
    for (int i = 0; i < m.length; ++i) m.bytes[i] = bytes[i];
}

void isd_synth_render(ISDSynth *s, float *left, float *right, int frames) {
    if (!s || frames <= 0) return;
    isd::DenormalGuard guard;
    if (s->allOff.exchange(false)) s->engine->allNotesOff();
    applyParams(s);
    // Stable sort by offset (events usually arrive in order).
    for (int i = 1; i < s->eventCount; ++i) {
        MidiEvent e = s->events[i];
        int j = i - 1;
        while (j >= 0 && s->events[j].offset > e.offset) { s->events[j + 1] = s->events[j]; --j; }
        s->events[j + 1] = e;
    }
    int pos = 0;
    for (int i = 0; i < s->eventCount; ++i) {
        int at = std::min(s->events[i].offset, frames);
        if (at > pos) { s->engine->render(left + pos, right + pos, at - pos); pos = at; }
        handleMidi(*s->engine, s->events[i]);
    }
    if (pos < frames) s->engine->render(left + pos, right + pos, frames - pos);
    s->eventCount = 0;
    s->voices.store(s->engine->activeVoices(), std::memory_order_relaxed);
}

void isd_synth_all_notes_off(ISDSynth *s) { if (s) s->allOff.store(true); }

int isd_synth_active_voices(const ISDSynth *s) { return s ? s->voices.load(std::memory_order_relaxed) : 0; }

int isd_synth_debug_count(const ISDSynth *s, ISDDebugCount which) { return s && s->engine ? s->engine->debugCount((int)which) : 0; }

// The engine keeps both in atomics and reads them once per control block, so any thread may call these.
void isd_synth_set_tension(ISDSynth *s, float tension) { if (s && s->engine) s->engine->setTension(tension); }

void isd_synth_trigger_drop(ISDSynth *s) { if (s && s->engine) s->engine->triggerDrop(); }

} // extern "C"
