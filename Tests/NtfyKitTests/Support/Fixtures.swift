enum Fixtures {
    /// A full message: title, tags, click, one view action, markdown content type.
    static let richMessage = #"""
    {"id":"XhKkViRHS9hx","time":1788335966,"expires":1788379166,"event":"message","topic":"alerts","title":"Service recovered","message":"**db-01** back to healthy","priority":3,"tags":["white_check_mark"],"click":"https://example.com/status","actions":[{"id":"80ka2OegsR","action":"view","label":"Open","clear":false,"url":"https://example.com/hosts/1"}],"content_type":"text/markdown"}
    """#

    /// The minimum a message can be: no title, no tags, no priority.
    static let minimalMessage = #"""
    {"id":"J7rfOekQUOkP","time":1788353322,"expires":1788396522,"event":"message","topic":"alerts","message":"A1"}
    """#

    /// Sent first on every stream.
    static let openEvent = #"""
    {"id":"m7A9VeCXrXcV","time":1788352812,"event":"open","topic":"alerts"}
    """#

    static let keepaliveEvent = #"""
    {"id":"kA1","time":1788352857,"event":"keepalive","topic":"alerts"}
    """#

    /// A keepalive whose server time is *later* than `minimalMessage`'s, so a
    /// script can take the steady-state shape a real stream has: the message,
    /// then the keepalive that proves the server has delivered everything up
    /// to that point. `keepaliveEvent` above is deliberately *older* than
    /// `minimalMessage`, so reusing it here would assert the resume point
    /// backwards.
    static let laterKeepaliveEvent = #"""
    {"id":"kA2","time":1788353400,"event":"keepalive","topic":"alerts"}
    """#

    /// An event type this version of the app does not know about.
    static let unknownEvent = #"""
    {"id":"zZ9","time":1788352900,"event":"some_future_event","topic":"alerts"}
    """#

    static let messageWithAttachment = #"""
    {"id":"att1","time":1788353000,"event":"message","topic":"alerts","message":"see attached","attachment":{"name":"graph.png","url":"https://example.com/f/graph.png","type":"image/png","size":4096,"expires":1788396200}}
    """#
}
