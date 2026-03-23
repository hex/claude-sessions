Published Time: 2026-03-22T20:36:33.040111

# Tool System | NousResearch/hermes-agent | DeepWiki

Index your code with Devin

[DeepWiki](https://deepwiki.com/)

[DeepWiki](https://deepwiki.com/)
[NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent "Open repository")

Index your code with

Devin

Edit Wiki Share

Last indexed: 22 March 2026 ([fa6f06](https://github.com/NousResearch/hermes-agent/commits/fa6f0695))

*   [Overview](https://deepwiki.com/NousResearch/hermes-agent/1-overview)
*   [Architecture Overview](https://deepwiki.com/NousResearch/hermes-agent/1.1-architecture-overview)
*   [Project Structure and Dependencies](https://deepwiki.com/NousResearch/hermes-agent/1.2-project-structure-and-dependencies)
*   [Getting Started](https://deepwiki.com/NousResearch/hermes-agent/2-getting-started)
*   [Installation](https://deepwiki.com/NousResearch/hermes-agent/2.1-installation)
*   [Configuration and Setup](https://deepwiki.com/NousResearch/hermes-agent/2.2-configuration-and-setup)
*   [Authentication and Providers](https://deepwiki.com/NousResearch/hermes-agent/2.3-authentication-and-providers)
*   [Model Selection and Management](https://deepwiki.com/NousResearch/hermes-agent/2.4-model-selection-and-management)
*   [CLI](https://deepwiki.com/NousResearch/hermes-agent/3-cli)
*   [Interactive Chat](https://deepwiki.com/NousResearch/hermes-agent/3.1-interactive-chat)
*   [Command Reference](https://deepwiki.com/NousResearch/hermes-agent/3.2-command-reference)
*   [Core Agent](https://deepwiki.com/NousResearch/hermes-agent/4-core-agent)
*   [Conversation Loop](https://deepwiki.com/NousResearch/hermes-agent/4.1-conversation-loop)
*   [Context and Prompt Management](https://deepwiki.com/NousResearch/hermes-agent/4.2-context-and-prompt-management)
*   [Memory and Sessions](https://deepwiki.com/NousResearch/hermes-agent/4.3-memory-and-sessions)
*   [Honcho Integration](https://deepwiki.com/NousResearch/hermes-agent/4.4-honcho-integration)
*   [Auxiliary Client](https://deepwiki.com/NousResearch/hermes-agent/4.5-auxiliary-client)
*   [Tool System](https://deepwiki.com/NousResearch/hermes-agent/5-tool-system)
*   [Tool Registry and Toolsets](https://deepwiki.com/NousResearch/hermes-agent/5.1-tool-registry-and-toolsets)
*   [Terminal and File Operations](https://deepwiki.com/NousResearch/hermes-agent/5.2-terminal-and-file-operations)
*   [Process Management](https://deepwiki.com/NousResearch/hermes-agent/5.3-process-management)
*   [Security and Command Approval](https://deepwiki.com/NousResearch/hermes-agent/5.4-security-and-command-approval)
*   [Web, Browser, and Vision Tools](https://deepwiki.com/NousResearch/hermes-agent/5.5-web-browser-and-vision-tools)
*   [Code Execution and MCP Tools](https://deepwiki.com/NousResearch/hermes-agent/5.6-code-execution-and-mcp-tools)
*   [Subagent Delegation](https://deepwiki.com/NousResearch/hermes-agent/5.7-subagent-delegation)
*   [Other Tools](https://deepwiki.com/NousResearch/hermes-agent/5.8-other-tools)
*   [Execution Environments](https://deepwiki.com/NousResearch/hermes-agent/6-execution-environments)
*   [Environment Abstraction](https://deepwiki.com/NousResearch/hermes-agent/6.1-environment-abstraction)
*   [Backend Implementations](https://deepwiki.com/NousResearch/hermes-agent/6.2-backend-implementations)
*   [Messaging Gateway](https://deepwiki.com/NousResearch/hermes-agent/7-messaging-gateway)
*   [Gateway Architecture](https://deepwiki.com/NousResearch/hermes-agent/7.1-gateway-architecture)
*   [Platform Adapters](https://deepwiki.com/NousResearch/hermes-agent/7.2-platform-adapters)
*   [Session and Media Management](https://deepwiki.com/NousResearch/hermes-agent/7.3-session-and-media-management)
*   [Security and Pairing](https://deepwiki.com/NousResearch/hermes-agent/7.4-security-and-pairing)
*   [Skills System](https://deepwiki.com/NousResearch/hermes-agent/8-skills-system)
*   [Skills Management and Security](https://deepwiki.com/NousResearch/hermes-agent/8.1-skills-management-and-security)
*   [Skills Hub](https://deepwiki.com/NousResearch/hermes-agent/8.2-skills-hub)
*   [Batch Processing](https://deepwiki.com/NousResearch/hermes-agent/9-batch-processing)
*   [Batch Runner](https://deepwiki.com/NousResearch/hermes-agent/9.1-batch-runner)
*   [Toolset Distributions](https://deepwiki.com/NousResearch/hermes-agent/9.2-toolset-distributions)
*   [Data Generation and Trajectories](https://deepwiki.com/NousResearch/hermes-agent/9.3-data-generation-and-trajectories)
*   [Advanced Topics](https://deepwiki.com/NousResearch/hermes-agent/10-advanced-topics)
*   [Context Compression](https://deepwiki.com/NousResearch/hermes-agent/10.1-context-compression)
*   [Provider Runtime Resolution](https://deepwiki.com/NousResearch/hermes-agent/10.2-provider-runtime-resolution)
*   [Cron and Scheduled Tasks](https://deepwiki.com/NousResearch/hermes-agent/10.3-cron-and-scheduled-tasks)
*   [Diagnostic Tools](https://deepwiki.com/NousResearch/hermes-agent/10.4-diagnostic-tools)
*   [RL Training Environments](https://deepwiki.com/NousResearch/hermes-agent/10.5-rl-training-environments)
*   [ACP Server and IDE Integration](https://deepwiki.com/NousResearch/hermes-agent/10.6-acp-server-and-ide-integration)
*   [Voice and TTS](https://deepwiki.com/NousResearch/hermes-agent/11-voice-and-tts)
*   [Voice Mode](https://deepwiki.com/NousResearch/hermes-agent/11.1-voice-mode)
*   [TTS and Transcription](https://deepwiki.com/NousResearch/hermes-agent/11.2-tts-and-transcription)
*   [Glossary](https://deepwiki.com/NousResearch/hermes-agent/12-glossary)

Menu

# Tool System

Relevant source files
*   [model_tools.py](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/model_tools.py)
*   [tests/agent/test_display_emoji.py](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tests/agent/test_display_emoji.py)
*   [tests/tools/test_registry.py](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tests/tools/test_registry.py)
*   [tools/__init__.py](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/__init__.py)
*   [tools/registry.py](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/registry.py)
*   [tools/terminal_tool.py](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/terminal_tool.py)
*   [toolsets.py](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/toolsets.py)

The tool system provides the agent's action capabilities through a function-calling architecture. This page covers the registry pattern, tool structure, discovery/dispatch mechanisms, and toolset composition. For specific tool implementations, see subsections [Terminal and File Operations](https://deepwiki.com/NousResearch/hermes-agent/5.2-terminal-and-file-operations) through [Other Tools](https://deepwiki.com/NousResearch/hermes-agent/5.8-other-tools). For the agent conversation loop that invokes tools, see [Core Agent](https://deepwiki.com/NousResearch/hermes-agent/4-core-agent).

## Architecture Overview

The tool system uses a centralized registry pattern where each tool module self-registers its schema, handler, and availability check at import time. The `model_tools.py` orchestration layer triggers discovery by importing all tool modules, then provides a unified API for schema collection and dispatch [model_tools.py 1-21](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/model_tools.py#L1-L21)

**Key components:**

*   **`tools/registry.py`** - Central `ToolRegistry` singleton holding all `ToolEntry` metadata [tools/registry.py 45-50](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/registry.py#L45-L50)
*   **`model_tools.py`** - Public API wrapping the registry (schema provider + dispatcher) [model_tools.py 11-20](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/model_tools.py#L11-L20)
*   **Individual tool modules** - Each registers via `registry.register()` at module-import time [tools/registry.py 56-68](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/registry.py#L56-L68)
*   **`toolsets.py`** - Tool grouping system for scenario-based filtering [toolsets.py 1-24](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/toolsets.py#L1-L24)

All tools return JSON strings. The registry wraps handler exceptions in `{"error": "..."}` automatically to maintain consistent LLM feedback [tools/registry.py 121-132](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/registry.py#L121-L132)

Sources: [model_tools.py 1-30](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/model_tools.py#L1-L30)[toolsets.py 1-24](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/toolsets.py#L1-L24)[tools/registry.py 1-132](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/registry.py#L1-L132)

## Tool Registration and Discovery

Tools register themselves when their module is imported. The `model_tools._discover_tools()` function imports all tool modules sequentially, triggering their registration calls.

### Tool Discovery Flow

Title: Tool Discovery Sequence

**Discovery module list**[model_tools.py 133-162](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/model_tools.py#L133-L162): The `_discover_tools()` function explicitly imports modules including `tools.web_tools`, `tools.terminal_tool`, `tools.file_tools`, `tools.browser_tool`, `tools.honcho_tools`, and others to populate the registry.

Import failures are logged but don't block other tools [model_tools.py 164-168](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/model_tools.py#L164-L168) Additionally, MCP tools and plugin tools are discovered dynamically [model_tools.py 174-185](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/model_tools.py#L174-L185)

Sources: [model_tools.py 133-185](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/model_tools.py#L133-L185)[tools/registry.py 56-82](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/registry.py#L56-L82)

## Tool Structure

Each tool consists of components registered via the `ToolEntry` class [tools/registry.py 24-43](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/registry.py#L24-L43):

### Schema (OpenAI Function Format)

Tools define their interface using JSON Schema. For example, the `todo` tool uses `TODO_SCHEMA`[tools/__init__.py 132](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/__init__.py#L132-L132) and `execute_code` uses `EXECUTE_CODE_SCHEMA`[tools/__init__.py 147](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/__init__.py#L147-L147)

### Handler Function

Signature: `handler(args: dict, **kwargs) -> str`

**Standard kwargs:**

*   `task_id: str` - Session isolation key for stateful tools (terminal, browser).
*   `user_task: str` - Original user request.

Handlers must return a JSON string. The registry catches exceptions and wraps them in `{"error": "..."}`[tools/registry.py 131-132](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/registry.py#L131-L132)

### Check Function

Returns `bool` indicating whether the tool is available (checks API keys, dependencies, etc.). Tools whose check fails are excluded from schema collection [tools/registry.py 98-107](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/registry.py#L98-L107) Examples include `check_terminal_requirements()`[tools/__init__.py 29](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/__init__.py#L29-L29) and `check_browser_requirements()`[tools/__init__.py 81](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/__init__.py#L81-L81)

Sources: [tools/__init__.py 1-261](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/__init__.py#L1-L261)[tools/registry.py 24-43](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/registry.py#L24-L43)[tools/registry.py 87-109](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/registry.py#L87-L109)

## Tool Dispatch Flow

### Invocation Logic

Title: Runtime Tool Execution

**Dispatching Mechanism**: The `registry.dispatch()` method handles both synchronous and asynchronous tools. If a tool is marked `is_async=True`, it automatically routes through `_run_async()` to bridge to the synchronous agent loop [tools/registry.py 126-128](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/registry.py#L126-L128)

Sources: [model_tools.py 11-20](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/model_tools.py#L11-L20)[tools/registry.py 115-132](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/registry.py#L115-L132)

## Toolsets

Toolsets group tools for scenario-based filtering. Each toolset in `toolsets.py` declares a description, a list of tools, and other toolsets to include [toolsets.py 72-209](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/toolsets.py#L72-L209)

**Built-in toolsets**[toolsets.py 72-269](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/toolsets.py#L72-L269):

| Toolset | Purpose | Key Tools |
| --- | --- | --- |
| `web` | Web research | `web_search`, `web_extract` |
| `terminal` | Command execution | `terminal`, `process` |
| `file` | File manipulation | `read_file`, `write_file`, `patch` |
| `browser` | Browser automation | `browser_navigate`, `browser_click` |
| `vision` | Image analysis | `vision_analyze` |
| `honcho` | AI-native memory | `honcho_context`, `honcho_search` |

**Core tools list**[toolsets.py 31-67](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/toolsets.py#L31-L67): `_HERMES_CORE_TOOLS` defines the full tool set shared by CLI and messaging platforms, ensuring consistency across environments.

### Toolset Composition

Toolsets can include other toolsets. For example, the `browser` toolset includes `web_search`[toolsets.py 122](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/toolsets.py#L122-L122) The resolution logic in `toolsets.py` handles recursive inclusion and deduplication.

Sources: [toolsets.py 31-209](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/toolsets.py#L31-L209)[tools/registry.py 156-174](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/registry.py#L156-L174)

## Tool Categories

The tool ecosystem spans multiple capability domains:

| Category | Tools | Description | Details |
| --- | --- | --- | --- |
| **Terminal & Files** | `terminal`, `process`, `read_file`, `patch` | Command execution and file I/O | See [Terminal and File Operations](https://deepwiki.com/NousResearch/hermes-agent/5.2-terminal-and-file-operations), [Process Management](https://deepwiki.com/NousResearch/hermes-agent/5.3-process-management) |
| **Web & Browser** | `web_search`, `browser_*` | Research and automation | See [Web, Browser, and Vision Tools](https://deepwiki.com/NousResearch/hermes-agent/5.5-web-browser-and-vision-tools) |
| **Vision & Generation** | `vision_analyze`, `image_generate` | Image analysis and generation | See [Web, Browser, and Vision Tools](https://deepwiki.com/NousResearch/hermes-agent/5.5-web-browser-and-vision-tools) |
| **Code Execution** | `execute_code` | Sandboxed Python tool calling | See [Code Execution and MCP Tools](https://deepwiki.com/NousResearch/hermes-agent/5.6-code-execution-and-mcp-tools) |
| **Delegation** | `delegate_task` | Spawn child agents | See [Subagent Delegation](https://deepwiki.com/NousResearch/hermes-agent/5.7-subagent-delegation) |
| **Skills** | `skills_list`, `skill_manage` | Knowledge document management | See [Skills System](https://deepwiki.com/NousResearch/hermes-agent/8-skills-system) |
| **Messaging** | `clarify`, `send_message` | Interaction and cross-platform chat | See [Other Tools](https://deepwiki.com/NousResearch/hermes-agent/5.8-other-tools) |

Sources: [tools/__init__.py 1-261](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/__init__.py#L1-L261)[toolsets.py 72-209](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/toolsets.py#L72-L209)

## Async Tool Support

Many tools use async handlers (e.g., `web_extract`, `browser` tools, `honcho` tools). `model_tools.py` provides a robust `_run_async` bridge to execute these from the agent's synchronous loop [model_tools.py 82-126](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/model_tools.py#L82-L126)

**Async Bridging Strategy**:

*   **Persistent Main Loop**: Uses a long-lived loop for the main thread to avoid "Event loop is closed" errors during garbage collection of async clients [model_tools.py 44-57](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/model_tools.py#L44-L57)
*   **Worker Thread Local Loops**: Uses thread-local loops for worker threads (e.g., during parallel tool execution or delegation) [model_tools.py 59-79](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/model_tools.py#L59-L79)
*   **Fresh Thread Fallback**: Detects if already inside an async context (like the Gateway or RL environment) and spawns a fresh thread to avoid loop conflicts [model_tools.py 108-113](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/model_tools.py#L108-L113)

Sources: [model_tools.py 36-126](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/model_tools.py#L36-L126)[tools/registry.py 126-128](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/registry.py#L126-L128)

## Terminal and File Tool Integration

File tools delegate to the terminal backend rather than implementing their own execution. This ensures that `read_file` or `patch` works identically across different execution environments (local, Docker, Modal).

### Environment Sharing

Title: File Tool and Terminal Integration

**Key Integration Points**:

*   **Requirement Sharing**: `check_file_requirements()` directly invokes `check_terminal_requirements()`[tools/__init__.py 158-161](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/__init__.py#L158-L161)
*   **Execution**: File tools use the terminal backend to perform operations, ensuring consistency in permissions and path resolution [tools/__init__.py 157](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/__init__.py#L157-L157)

Sources: [tools/__init__.py 158-161](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/__init__.py#L158-L161)[tools/terminal_tool.py 1-40](https://github.com/NousResearch/hermes-agent/blob/fa6f0695/tools/terminal_tool.py#L1-L40)

Dismiss
Refresh this wiki

This wiki was recently refreshed. Please wait 7 day s to refresh again.

### On this page

*   [Tool System](https://deepwiki.com/NousResearch/hermes-agent/5-memory-systems#tool-system)
*   [Architecture Overview](https://deepwiki.com/NousResearch/hermes-agent/5-memory-systems#architecture-overview)
*   [Tool Registration and Discovery](https://deepwiki.com/NousResearch/hermes-agent/5-memory-systems#tool-registration-and-discovery)
*   [Tool Discovery Flow](https://deepwiki.com/NousResearch/hermes-agent/5-memory-systems#tool-discovery-flow)
*   [Tool Structure](https://deepwiki.com/NousResearch/hermes-agent/5-memory-systems#tool-structure)
*   [Schema (OpenAI Function Format)](https://deepwiki.com/NousResearch/hermes-agent/5-memory-systems#schema-openai-function-format)
*   [Handler Function](https://deepwiki.com/NousResearch/hermes-agent/5-memory-systems#handler-function)
*   [Check Function](https://deepwiki.com/NousResearch/hermes-agent/5-memory-systems#check-function)
*   [Tool Dispatch Flow](https://deepwiki.com/NousResearch/hermes-agent/5-memory-systems#tool-dispatch-flow)
*   [Invocation Logic](https://deepwiki.com/NousResearch/hermes-agent/5-memory-systems#invocation-logic)
*   [Toolsets](https://deepwiki.com/NousResearch/hermes-agent/5-memory-systems#toolsets)
*   [Toolset Composition](https://deepwiki.com/NousResearch/hermes-agent/5-memory-systems#toolset-composition)
*   [Tool Categories](https://deepwiki.com/NousResearch/hermes-agent/5-memory-systems#tool-categories)
*   [Async Tool Support](https://deepwiki.com/NousResearch/hermes-agent/5-memory-systems#async-tool-support)
*   [Terminal and File Tool Integration](https://deepwiki.com/NousResearch/hermes-agent/5-memory-systems#terminal-and-file-tool-integration)
*   [Environment Sharing](https://deepwiki.com/NousResearch/hermes-agent/5-memory-systems#environment-sharing)

Ask Devin about NousResearch/hermes-agent

Fast
