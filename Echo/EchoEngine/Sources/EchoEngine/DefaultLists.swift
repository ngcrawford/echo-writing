public enum DefaultLists {
    /// Words never flagged as proximity repeats: articles, pronouns, prepositions, auxiliaries, conjunctions,
    /// common contractions, and the dialogue tag *said*.
    public static let exclude: [String] = """
        a an the
        i me my mine myself we us our ours ourselves you your yours yourself yourselves
        he him his himself she her hers herself it its itself they them their theirs themselves
        this that these those who whom whose which what where when why how
        am is are was were be been being have has had having do does did doing done
        will would shall should can could may might must
        and but or nor so yet for if then than because as while until unless though although whether
        of at by with about against between into through during before after above below
        to from up down in out on off over under again further once here there
        all any both each few more most other some such no not only own same too
        don't didn't doesn't isn't wasn't weren't aren't won't wouldn't couldn't shouldn't can't hadn't hasn't haven't
        i'm i'd i'll i've you're you'd you'll you've he's he'd he'll she's she'd she'll it's it'd it'll
        we're we'd we'll we've they're they'd they'll they've that's there's what's let's
        said
        """.split(whereSeparator: \.isWhitespace).map(String.init)

    /// Optional starter pack for the watch list (SPEC §4.4). Not enabled by default.
    public static let watchStarterPack: [String] = [
        "just", "really", "very", "suddenly", "that", "began to", "started to",
        "seemed", "felt", "realized", "a bit", "somehow",
    ]
}
