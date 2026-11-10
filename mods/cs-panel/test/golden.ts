// ABOUTME: tests/fixtures/config-porcelain.txt, the golden `cs -config list --porcelain`, as a literal the kit can import (the kit reads no file).
// ABOUTME: tests/test_mod_panel.sh holds the text between the backticks to that fixture, byte for byte.
export const GOLDEN = `CS_STATUSLINE_DISABLE	Status line	Status line	flagoff	-	off	now	applies at the next repaint	-	default	-	Draws the line under the prompt with the session, branch, model, context and usage limits.
CS_STATUSLINE_LAYOUT	Status line	Layout	choice	quiet,band,capsules	quiet	now	applies at the next repaint	band	machine	-	How the status line looks: plain text, one full-width band of colour, or capsules.
CS_STATUSLINE_SEGMENTS	Status line	Segments	text	-	logo,session,notes,mail,git,model,ctx,limits	now	applies at the next repaint	-	default	-	Which items the status line shows, in order, as a comma-separated list.
CS_STATUSLINE_BAND	Status line	Band colour	text	-	session	now	applies at the next repaint	-	default	machine line 4: CS_STATUSLINE_BAND=magenta: not a palette name, brand, periwinkle, session, none or r;g;b	The colour of the band and the session chip; session gives each session its own colour.
CS_STATUSLINE_COLS	Status line	Width in columns	text	-	measured	now	applies at the next repaint	-	default	-	A fixed width for the status line; unset, it fits the terminal.
CS_STATUSLINE_FRAME	Status line	Frame columns	text	-	4	now	applies at the next repaint	6	shell	-	Columns the prompt frame takes from the measured width, so the line is not cut short.
CS_STATUSLINE_CTX_WARN	Status line	Context warn %	text	-	40	now	applies at the next repaint	50	session	-	Context use at which the gauge turns to its warning colour.
CS_STATUSLINE_CTX_CRIT	Status line	Context critical %	text	-	60	now	applies at the next repaint	-	default	-	Context use at which the gauge turns to its critical colour.
CS_USAGE_NO_REFRESH	Status line	Usage refresh	flagoff	-	off	now	applies at the next repaint	-	default	-	Fetches your Fable usage for the status line; off, it shows only what is already cached.
CS_SUBAGENT_STATUSLINE_DISABLE	Status line	Subagent rows	flagoff	-	off	now	applies at the next repaint	-	default	-	Styles the rows Claude Code shows for running subagents to match the status line.
CS_SCOPE_DISABLE	Prompts	Scope grounding	flagoff	-	off	now	applies at your next prompt	1	session	-	Adds a short summary of the relevant code to each prompt that asks for code work.
CS_SCOPE_TRACE_DISABLE	Prompts	Scope trace	flagoff	-	off	now	applies at your next prompt	-	default	-	Logs how long each step cs runs on your prompt takes, to find a slow or stuck one.
CS_SCOPE_BUDGET_MS	Prompts	Scope scan budget (ms)	text	-	1500	now	applies at your next prompt	-	default	-	If the first steps on a prompt take longer than this, cs skips its code scan; 0 always skips it.
CS_OBJECTIVE_CAPTURE_DISABLE	Prompts	Objective capture	flagoff	-	off	now	applies at your next prompt	-	default	-	Records the first real prompt of a session as its objective in .cs/README.md.
CS_DATE_REMINDER_DISABLE	Prompts	Date reminder	flagoff	-	off	now	applies at your next prompt	-	default	-	Tells Claude the new date when a conversation runs past midnight.
CS_CLARIFY_DISABLE	Prompts	Clarifying questions	flagoff	-	off	now	applies at your next prompt	-	default	-	Asks Claude to question an unclear request instead of guessing; a leading ~ skips one prompt.
CS_NARRATIVE_PROMPT_DISABLE	Prompts	Narrative line	flagoff	-	off	now	applies at your next prompt	-	default	-	Asks Claude, on each prompt, to note a finding in its narrative before it answers.
CS_CTX_WARN_CTX	Rotation	Context warning %	text	-	40	now	applies when the next turn ends	-	default	-	Context use at which Claude tells you, once, that the conversation is filling up.
CS_ROTATE_BUTTON_CTX	Rotation	Rotate button from %	text	-	the warn %	now	applies by your next prompt	-	default	-	Context use from which the band above the prompt shows the rotate key, Ctrl+X 1.
CS_ROTATE_NUDGE_CTX	Rotation	Rotation nudge %	text	-	60	now	applies when the next turn ends	-	default	-	Context use at which Claude suggests, once, writing a handoff and going on after /clear.
CS_ROTATE_FORCE_CTX	Rotation	Rotate on its own past %	text	-	80	now	applies by your next prompt	-	default	session line 4: CS_ROTATE_FORCE_CTX=101: not off, 0 or a percentage from 1 to 100	Context use past which cs rotates by itself after a 20 second countdown you can stop.
CS_NO_ROTATION_WAKE	Rotation	Wake after /clear	flagoff	-	off	/clear	applies at the next /clear or launch	-	default	-	After /clear on a handoff, the fresh conversation starts its next step without you typing.
CS_ROTATION_KICK_DELAY	Rotation	Wake delay (s)	text	-	2	now	applies at the next rotation	-	default	-	Seconds between tries to wake the fresh conversation after /clear; 0 tries once.
CS_BAND_PROMPTS	Prompt bars	Prompt bars	flag	-	off	now	applies by your next prompt	-	default	-	Draws a bar per prompt on the band above the prompt; a press on a bar scrolls the transcript to it.
CS_BAND_PROMPT	Prompt bars	Named prompt	choice	latest,read	latest	now	applies by your next prompt	-	default	-	The prompt the band names and draws thick: latest, the newest, or read, the one at the top of the screen.
CS_BAND_BARS	Prompt bars	Most bars	text	-	10	now	applies by your next prompt	-	default	-	The most prompt bars the band draws; the prompts past them fold into a count at either end.
CS_REWRITE_PROVIDER	Rewriter (ctrl+g)	Provider	choice	claude,claude-api,openai,openai-api,gemini,gemini-api,grok,xai	claude	now	applies at the next ctrl+g	-	default	-	Who rewrites your prompt; an -api choice calls the vendor API in place of its CLI.
CS_REWRITE_MODEL	Rewriter (ctrl+g)	Model	text	-	per provider	now	applies at the next ctrl+g	-	default	-	The model that rewrites your prompt, by the provider name for it; unset, the provider picks.
CS_REWRITE_TIMEOUT	Rewriter (ctrl+g)	Timeout (s)	text	-	25	now	applies at the next ctrl+g	-	default	-	Seconds to wait for a rewrite before your prompt is left as you typed it.
CS_REWRITE_PROGRESS	Rewriter (ctrl+g)	Progress	choice	screen,native,line,static	screen	now	applies at the next ctrl+g	-	default	-	What the screen shows while ctrl+g waits for the rewrite.
CS_REWRITE_DISABLE	Rewriter (ctrl+g)	Rewrite (ctrl+g)	flagoff	-	off	now+launch	stopping rewrites: the next ctrl+g. Starting them after a launch without them: the next launch, which installs the ctrl+g shim.	-	default	-	Ctrl+g in the prompt rewrites what you typed into a clearer prompt before you send it.
CS_TERM_THEME	Terminal	Theme	choice	light,dark	detected	now	applies at the next repaint	dark	launch	-	Whether cs draws for a light or a dark terminal; unset, cs detects it at launch.
CS_TERM_BG_RGB	Terminal	Background r;g;b	text	-	detected	now	applies at the next repaint	-	default	-	Your terminal background colour, which the status line shades its capsules from.
CS_NO_ITERM2	Terminal	iTerm2 features	flagoff	-	off	now+launch	the tab title, the bell bounce and the iTerm reads of the bar: now. The iTerm tmux path of the launch: the next launch.	-	default	-	Uses iTerm2 for the tab title, a dock bounce when a turn ends and the theme of your profile.
CS_NERD_FONTS	Terminal	Nerd Font glyphs	flag	-	off	now	applies at the next cs command	-	default	-	Shows Nerd Font icons in cs banners and session lists; needs a Nerd Font in the terminal.
CS_FILTER_CHAT	Terminal	Filter chat	flag	-	off	now+launch	/filter-chat and the band key: now. A change here or in a shell: the next launch.	-	default	-	Shows only your prompts and the replies from Claude in this session; the band key or /filter-chat flips it.
CS_NO_MAIL_WAKE	Mail	Wake on mail	flagoff	-	off	now	applies when the next turn ends	-	session	-	Unread mail from another session takes a turn, so the exchange goes on without you typing.
CS_MAIL_WAKE_MAX	Mail	Wakes in a row	text	-	5	now	applies when the next turn ends	-	default	-	How many turns mail may take in a row before it waits for a prompt from you.
CS_NO_TASK_TOOLS	Launch	Task tools	flagoff	-	off	launch	applies at the next launch	-	default	-	Gives Claude its task list tools on every model, for rotation, the queue and handoffs.
CS_NO_UPDATE_CHECK	Launch	Update check	flagoff	-	off	launch	applies at the next launch	-	default	-	Asks GitHub for a newer cs at most hourly; off, cs makes no network request for it.
CS_NO_FUNCTION_HOOKS	Launch	Mods	shelloff	-	off	launch	applies at the next launch; with mods off, the cs panel does not load either	-	default	-	Lets a launch load mods, the cs band and settings pane among them; off, none loads.
CS_QUEUE_MAX_FAILURES	Queue	Stops after failures	text	-	5	now	applies when the next turn ends	-	default	-	A queue run stops once one task has this many failed tool calls.
CS_QUEUE_MAX_CTX	Queue	Stops past context %	text	-	85	now	applies when the next turn ends	-	default	-	A queue run stops before its next task once context use reaches this.
CS_QUEUE_MAX_5H	Queue	Stops past 5h limit %	text	-	85	now	applies when the next turn ends	-	default	-	A queue run stops before its next task once your 5-hour usage limit reaches this.
CS_NARRATIVE_MAX_BYTES	Narrative	Budget (bytes)	text	-	131072	now	applies when the next turn ends	-	default	-	Size past which a session narrative is due to move its older sections to the archive.
CS_NARRATIVE_KEEP_BYTES	Narrative	Tail kept (bytes)	text	-	65536	now	applies when the next turn ends	-	default	-	How much of the newest narrative stays in the live file when it rotates.
`
