---
name: show-image
description: This skill should be used when the user asks to see, show or display an image, screenshot, photo or chart that is a file on disk, or asks for an explanation in pictures, such as "show me in pictures", "explain it visually" or "draw me a picture".
---

Write one line holding only `![short name](/absolute/path)`, outside any code block. Use an absolute path with no spaces in it. Replace `short name` with a brief name for the picture.

For example, write this line on its own:

![short name](/absolute/path.png)

Supported formats are png, jpg, jpeg, gif, heic, webp, tiff, bmp.

cs-images draws real pixels where the terminal allows them and coloured blocks elsewhere. With blocks, the picture is a preview. Small text is not readable.

## When the user asks to understand something in pictures

Use the first of these that fits, one picture for each point, with a few lines of prose beside it:

- A file on disk already shows it: draw that file with the line above.
- A flow, a structure or states: write a mermaid diagram in a ` ```mermaid ` fence.
- Anything a diagram cannot show, such as how a thing looks or how parts sit together: if a tool that generates images is available, make one image with one provider, then draw the absolute path the tool reports with the line above. If that path holds a space, copy the file to a path without one first.

If no such tool is available, draw a diagram and say you have no image tool. Never put secrets, credentials, client data or private file contents in an image description, because the description goes to an outside service; draw a diagram for those.
