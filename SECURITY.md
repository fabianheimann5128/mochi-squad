# Security

Mochi Squad starts AI agents on your Mac. This document describes what the app secures, what it does not, and how to report a vulnerability.

## Reporting a vulnerability

Please do **not** open a public issue. Use "Report a vulnerability" under the *Security* tab of this repository. You will get an answer within a few days.

## Security model

**Every agent runs in a sandbox** unless you explicitly give it full access or let it operate the computer (see below). What it may do inside is set per agent. The sandbox is provided by Claude Code and Codex; the limits of this approach are listed under "Known limits".

| Right | Default | How (Claude Code) |
|---|---|---|
| Read the project | always | read rule of the file tools for the project folder only. Commands in the sandbox can read outside it too, except at the locked places below |
| Change files in the project | off | only with "Edit in project"; otherwise the sandbox blocks writing in the project |
| Work without the sandbox | never | `allowUnsandboxedCommands: false`, and `failIfUnavailable: true`: if the sandbox cannot start, the client quits instead of working unprotected |
| Change client settings and Git hooks in the project (`.claude/`, `.codex/`, `.git/hooks/`, `.git/config`) | never | deny rule and write lock, so that an agent cannot give itself more rights or leave code for later sessions |
| Read credentials and other apps' data | never | locked for commands **and** for the client's own file tools: `~/.ssh`, `~/.aws`, `~/.codex`, `~/.claude`, the keychain, `~/Library/Application Support`, browser and mail data and more. Client folders you moved elsewhere (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`) are locked as well |
| Reach local network ports | never | sandboxed commands can neither open ports nor reach services on `localhost` |
| Internet in routines | off | can be switched on per routine; off means the web tools are denied outright |
| Publish, upload, pay | never on its own | instruction in the briefing; the client asks before anything risky |

The client's questions (for example "May I run this command?") appear as a card in the chat. You decide. Before an answer is sent, the app reads the console again: if the client shows a different question by then, nothing is sent.

**Launch data is out of the agents' reach.** What a session may do is written by the app into a session folder inside its own data. Agents can neither read nor write there, and the launcher accepts launch data only from that folder. Paths to tools are never part of this data; they follow from the folder.

**Project folders.** Mochi Squad accepts neither your home folder nor a folder above it as a project, and inside the home folder neither `~/Library` nor `~/Applications` nor hidden folders such as `~/.ssh`, `~/.claude` or `~/.codex`. Otherwise credentials and the app's own data would lie in an agent's working area.

**Agent post.** Every session has its own outbox. Only its own sandbox may write into it, which settles who sent a message. The post tool itself lies in a place no sandbox can write to.

**The coordinator's tools.** A coordinator talks to the app through a local server. The server listens only on `127.0.0.1`, on a random port. **Every coordinator session gets its own token**, created at its start and withdrawn at its end, so the app knows which session is asking. A request is judged by the rights of that session, never by those of another project's coordinator, and a caller the app does not know gets nothing. The token is in no file; the session receives it through its environment. Requests from a browser (with `Origin`) and with a foreign host name are refused. A coordinator loads no tool servers but the app's own.

**Collaboration.** Agents can send each other messages and bring in colleagues in the team chat. Only you reach the coordinator, in its own chat or in the team chat. Agents cannot send it anything, because through its tools it can hand out tasks across projects and read histories. Relays are limited to 24 per half hour per project and sessions to 8 at a time, so no loops arise.

**Credentials.** Mochi Squad stores no passwords or tokens of your subscriptions. The sign-in belongs to Claude Code or Codex. For extra ChatGPT plans Codex keeps its sign-in in an own folder under `~/Library/Application Support/Mochi Squad/accounts/`; that area is locked for all agents.

**Ending a session.** When you take rights away from an agent, its running session ends at once. The client and the programs it started receive a termination signal as a group; what is still alive a few seconds later is killed.

## Full access

Per agent, the access level "Full access" can be switched on. It is the explicit opposite of the rules above: the agent runs **without a sandbox and without confirmations** (Claude Code in `bypassPermissions` mode, Codex with `danger-full-access`) and can read, change and delete every file and program of your user account, including credentials, the app's data and other agents' outboxes. None of the assurances of this document holds for such an agent or for what it plants on other agents. The default is "Read only"; routines never run with full access. Use the level only for agents you trust completely, and not for agents that process foreign web pages or files.

## Operating the computer

Per agent, "Operate computer" can be switched on. Codex agents then keep Codex's computer control (screen, apps and browser). Claude agents get Claude Code's own desktop control (screenshots, mouse and keyboard in any app) and control the Chrome browser through Claude in Chrome. Claude Code keeps its desktop control off until it is enabled once per project in its `/mcp` dialog; Mochi Squad makes that choice for you before the first such session, in a short session of its own that sends nothing to the model. macOS asks you to allow Mochi Squad under Accessibility and Screen Recording. These tools run outside the sandbox: what the agent does through the screen or browser is not bound by the file limits above, and in the browser it acts with your sign-ins. The default is off; routines never operate the computer.

Codex's computer control stays on only if it is genuine: its program must lie inside the ChatGPT app, that app must carry OpenAI's code signature, its arguments must be plain switches, and the project must not bring a server of the same name.

## Rights between agents

An agent with full access or computer use can be addressed on its own initiative only by a colleague who may do the same; what counts is what that colleague's running session may do. This applies to agent post, to mentions in the team chat and to a coordinator's tasks. Otherwise it is reserved for you. Answers to someone who wrote within the last half hour are always possible. An agent receives the team chat's recent lines only from voices that could address it directly; the coordinator receives only your lines. Who wrote a line is decided by the agent's id, not by its name, so renaming an agent or reusing a name moves no lines. Between "Read only" and "Edit in project" there is no barrier; both work in the sandbox.

These rules lower the risk but do not remove it: an agent with full access reads files in the project that a restricted agent left there.

## Routines

A routine runs while you are away, so it trusts less than a chat does:

- It always runs in the sandbox, never with full access or computer use.
- With Claude Code it loads only your own user settings (`--setting-sources user`) and no tool servers: **hooks and servers a project brings along do not run**, because nobody is there to answer the trust question.
- With Codex the user's tool servers are switched off, and the list is taken in the project folder the routine runs in.
- Without "May search the web", the web tools are denied.
- The same routine never runs twice at once.
- **Keyword and start link.** A keyword routine starts when the paired messenger account writes its keyword; the rest of the message goes into the task. A start link (`mochisquad://run?routine=…&key=…`) carries a random 24-character key that is compared in constant time; anyone who has the link can start that routine, in the sandbox, with the text they add, and use up some of your plan by starting it again and again. Text from a link is handed to the agent as coming from an unknown sender, not from you. Create a new link if it leaked. Both work only while the app runs (a link opens the app).
- Rights, model and subscription of a routine always follow the agent as it is now. A form left open cannot bring back rights you took away.

## Skills

A skill is a folder with instructions (`SKILL.md`) and sometimes scripts. Whatever a skill says, an agent that has it will try to do, within its rights: **use only skills from sources you trust**, as you would with any program. Skills you installed in Claude Code (`~/.claude/skills`) or Codex (`~/.codex/skills`, `~/.agents/skills`) are linked automatically and then reach agents of both kinds; take one out in the Skills window if it should not. Mochi Squad keeps added skills in its own data, where agents can neither read nor change them, and gives the agents a copy to read. Sandboxed agents cannot change that copy; an agent with full access can, until the app rebuilds it at the next launch or change. Links inside a skill are removed on import, so a skill cannot point at files outside its folder. Which agent gets which skill is decided by the list in the app's data, never by anything in a project or a session file.

## Tidying up a conversation

"Summarise and start fresh" sends the text of the agent's latest conversation (the newest messages up to 60,000 characters) to a one-off run of the agent's own client, in an empty temporary folder, without saving a session: Claude Code with no tools, no tool servers and no hooks; Codex in a read-only sandbox with its shell, browser, plugins, hooks and your tool servers switched off (if the list of your tool servers cannot be read, nothing runs). The app notes the session, the conversation and the agent's program and plan when you click, and replaces nothing if any of them moved on while the summary was written. The new session starts with the summary; the old conversation stays readable under "More chats". The summary is as reliable as the model that wrote it.

## Mochi Memory

Agents save lasting facts with their post tool (`post remember`); the app writes them into Markdown notes in `~/Mochi Memory` or the folder you chose, each with the agent's name and the date. Only the app writes on behalf of agents, so the author is certain. Text that looks like a password, key or token is refused, and such lines written by hand are kept out of every briefing; this is pattern matching, so do not put secrets there yourself.

What is in memory goes into the briefing of the agents, marked as information and not as instructions, with who saved each line. An agent that can do more than others (full access, computer use, the coordinator) gets only what you wrote yourself and what agents with the same reach saved: a restricted agent that read a hostile web page cannot steer a privileged one through memory. Agents cannot read or write the memory folder directly; the sandbox locks it. Anyone and any program that can write to the folder can still change what your agents believe, so keep it in a place only you use. Changing the folder moves only Mochi notes; other Markdown files stay where they are.

## Messengers

Telegram and WhatsApp let you write to the coordinator of one project from your phone. **A message from a messenger reaches the coordinator and nobody else**, whatever it mentions, and only the coordinator's answers go back to the phone. The coordinator is reached with the rights you gave it, full access and computer use included, and can hand out work to other agents as it can in the app.

- **Telegram.** You create the bot; its token is kept in your macOS keychain and handed to the helper process through a pipe. The app reads the bot by polling; there is no server and no public address. Only private chats count, and after pairing only the one account you confirmed. Pairing needs a random one-time code that is valid for 15 minutes. Messages from anyone else are dropped.
- **WhatsApp.** The app links this Mac as a device of your account through the unofficial Baileys library, which is downloaded from the npm registry when you set WhatsApp up (install scripts of packages are not run). It reads and writes one chat only, "Message yourself"; all other chats are discarded before they are decrypted. WhatsApp does not permit unofficial clients and may block a number. The session is stored in the app data, which is locked for sandboxed agents.
- Whoever has your unlocked phone, or control of your Telegram or WhatsApp account, can give your coordinator tasks, with everything the coordinator is allowed to do. Keep that in mind when you choose the coordinator's access level, and lock your phone.

## Download and updates

The download is signed with the maintainer's Developer ID and notarized by Apple. Updates come through [Sparkle](https://sparkle-project.org): the app reads the update feed from this repository's latest GitHub release over HTTPS and installs a new version only if it carries the signature of the release key (EdDSA) whose public half is built into the app, and only after asking you. Copies built from source without that key never look for updates. The app runs with the hardened runtime; it asks macOS for the microphone (dictation) and for scripting other apps (computer use) and for nothing else.

## Attachments, dictation, background

- **Attachments** are copied to `<project>/.mochi-squad/attachments` and stay there; every agent of the project can read them. A message without files creates nothing, so plain text also works in a read-only project. If one of several files cannot be attached, none is left behind. The app shows previews only for files in that folder, only on your own messages, and only while the folder really lies inside the project. A click opens images; other files are revealed in Finder and never run directly.
- **Dictation** uses the microphone and speech recognition of macOS. Where macOS offers on-device recognition, the audio stays on the Mac; otherwise Apple processes it. Recording ends when you send, when you press stop and as soon as the app goes to the background. A permission answer that arrives after you left does not start a recording.
- **Running in the background** means: the app stays open and is only hidden. Open sessions keep working, including those with full access.

## Known limits

- **Prompt injection.** An agent that reads web pages or foreign files can follow instructions hidden in them. The rights above limit the damage but do not fully prevent it. Give write access and internet only to agents that need them, and keep important projects under version control.
- **Codex through a permission profile.** Codex agents get their own permission profile with the same read locks and write limits as Claude agents; it applies to the commands the agent runs. The profile name is random on every launch, so that a `.codex/config.toml` in the project cannot widen it. Before every launch Mochi Squad checks with `codex sandbox` that the installed client enforces the profile, and does not start otherwise. The check runs through that subcommand, not inside the session itself.
- **Your own tool servers.** Tool servers (MCP) from your personal or a project configuration run outside the sandbox. For Codex agents without full access Mochi Squad switches them off at launch. A coordinator loads only Mochi Squad's tools. Other Claude agents in a chat load your Claude Code servers; their tools ask before they run. With "Operate computer" the Chrome control is approved in advance and does not ask.
- **Foreign outboxes with Claude agents.** Codex agents see only their own outbox. Claude agents can read the outboxes of other sessions, but not write to them.
- **Foreign projects with their own configuration, in a chat.** A repository can bring settings for Claude Code (`.claude/settings.json`, such as hooks) or Codex. In a chat the programs ask on first opening whether you trust the folder; this question appears as an ordinary card. Confirm it only for projects whose origin you know, because such settings can trigger commands outside the sandbox. (Routines do not load them at all, see above.)
- **Git in the project.** Agents with write access cannot change `.git/hooks` and `.git/config`. As a result harmless commands such as `git init` or `git remote add` fail in the sandbox too; you run those yourself.
- **Local servers.** Because local ports are closed, a sandboxed agent cannot start a development server or run tests that open one. Do that yourself or give the agent full access for it.
- **The sandbox belongs to the client.** Mochi Squad configures the sandbox of Claude Code and Codex but builds none of its own. Its strength depends on the client's version. Approvals in your personal client settings apply in addition.
- **Reading in the project.** Every agent reads the whole project folder. Do not keep secrets there (such as a `.env` with production keys).
- **Internet in routines.** A routine with internet access runs unattended and can send content from the project to web sites if it is tricked into it. Switch that on only for projects without confidential content.
- **Processes that leave their group.** Ending a session reaches the client and its process group. A program that deliberately detached itself into its own session is not reached.
- **No separation between macOS users.** Mochi Squad does not protect against other programs running under your user account.
