/// What a recorded stem holds (Recorder spec §3): the app's instrument, a live input, the play-along, or the world's ambience.
public enum StemKind: String, Codable, Sendable, CaseIterable {
    case instrument, liveInput, playAlong, ambience
}
