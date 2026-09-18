// PromptCommandTests — the tag block Claude Code writes for a slash command, back into a line.
//
// The blocks here are copied shape-for-shape from real transcripts: message-first with arguments,
// message-first without, and the name-first echo a local command leaves behind, which must not
// parse as a prompt.

import Testing

@testable import AgentBridge

@Suite("PromptCommand")
struct PromptCommandTests {

    private static let skill = """
        <command-message>brainstorming-skill:brainstorming-skill</command-message>
        <command-name>/brainstorming-skill:brainstorming-skill</command-name>
        <command-args>We need to start work on ADO 3620.</command-args>
        """

    @Test("A skill invocation is its name and the arguments that followed it")
    func parsesMessageNameAndArguments() throws {
        let command = try #require(PromptCommand.parse(Self.skill))
        #expect(command.name == "/brainstorming-skill")
        #expect(command.arguments == "We need to start work on ADO 3620.")
        #expect(command.typedLine == "/brainstorming-skill We need to start work on ADO 3620.")
    }

    @Test("A duplicated name collapses; a plugin's command keeps both halves")
    func namesAreNormalized() {
        #expect(PromptCommand.normalize("impeccable:impeccable") == "/impeccable")
        #expect(PromptCommand.normalize("/frontinvest-team-tools:release-pr")
            == "/frontinvest-team-tools:release-pr")
        #expect(PromptCommand.normalize("/loop") == "/loop")
        #expect(PromptCommand.normalize("  /plan  ") == "/plan")
        #expect(PromptCommand.normalize("/") == nil)
        #expect(PromptCommand.normalize("two words") == nil)
    }

    @Test("A command invoked with nothing after it has no arguments")
    func aBareCommandHasNoArguments() throws {
        let block = """
            <command-message>brainstorming-skill:brainstorming-skill</command-message>
            <command-name>/brainstorming-skill:brainstorming-skill</command-name>
            """
        let command = try #require(PromptCommand.parse(block))
        #expect(command.arguments == nil)
        #expect(command.typedLine == "/brainstorming-skill")

        let empty = try #require(PromptCommand.parse(block + "\n<command-args></command-args>"))
        #expect(empty.arguments == nil)
    }

    @Test("Arguments keep their own newlines and lose only the whitespace at the ends")
    func multilineArguments() throws {
        let block = """
            <command-message>loop</command-message>
            <command-name>/loop</command-name>
            <command-args>
            First line.

            Second line.
            </command-args>
            """
        let command = try #require(PromptCommand.parse(block))
        #expect(command.arguments == "First line.\n\nSecond line.")
    }

    @Test("A local command's echo, and ordinary prose, are not command prompts")
    func nonCommandsAreLeftAlone() {
        #expect(PromptCommand.parse("<command-name>/clear</command-name>\n<command-message>clear</command-message>") == nil)
        #expect(PromptCommand.parse("Fix the build") == nil)
        #expect(PromptCommand.parse("Explain what <command-name> means in a transcript") == nil)
    }

    @Test("A torn line still yields what it has")
    func anUnclosedTagTakesTheRest() throws {
        let command = try #require(PromptCommand.parse(
            "<command-message>loop</command-message>\n<command-name>/loop</command-name>\n<command-args>keep going"))
        #expect(command.typedLine == "/loop keep going")
    }
}
