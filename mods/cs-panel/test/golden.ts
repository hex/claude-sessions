// ABOUTME: tests/fixtures/list-porcelain.txt, the golden `cs -list --porcelain` answer, as the kit can import it (it reads no file).
// ABOUTME: tests/test_mod_panel.sh holds the text between the backticks to that file byte for byte.
export const GOLDEN = `alpha	1	41	2	1
alpha@fix	0	12	0	0
alpha@stale	0	-	0	0
beta	0	-	-	0
`
