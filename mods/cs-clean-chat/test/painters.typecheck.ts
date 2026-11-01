// ABOUTME: Compile-time checks on the painter table: tsc fails if a refused shape stops being refused (each @ts-expect-error must still error).
// ABOUTME: Not loaded by the engine; run by `tsc -p` in tests/test_mod_clean_chat.sh.
import type { PainterTable } from '../hooks/register'

type ModePainter = PainterTable['SessionMode']

// The mode line may rewrite its props.
export const rewriting: ModePainter = () => ({ kind: 'rewrite', props: { modes: ['clean chat · /clean-chat to switch'] } })

// @ts-expect-error a mode line painter that returns a tree of its own is refused: the engine draws the row.
export const replacing: ModePainter = () => ({ kind: 'tree', tree: null as never })

// @ts-expect-error a mode line painter that draws nothing is refused too.
export const hiding: ModePainter = () => ({ kind: 'nothing' })

// @ts-expect-error a table missing a hooked site is refused.
export const partial: PainterTable = { SessionMode: rewriting }

// @ts-expect-error the row above the prompt is no site: it is cs's band.
export const above: PainterTable['AbovePrompt'] = () => ({ kind: 'nothing' })
