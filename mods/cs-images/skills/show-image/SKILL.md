---
name: show-image
description: This skill should be used when the user asks to see, show or display an image, screenshot, photo or chart that is a file on disk, or asks for an explanation in pictures, such as "show me in pictures", "explain it visually" or "draw me a picture".
---

Write one line holding only `![short name](/absolute/path)`, outside any code block. Use an absolute path with no spaces in it. Replace `short name` with a brief name for the picture.

For example, write this line on its own:

![short name](/absolute/path.png)

Supported formats are png, jpg, jpeg, gif, heic, webp, tif, tiff, bmp, in any letter case.

cs-images draws real pixels where the terminal allows them and coloured blocks elsewhere. With blocks, the picture is a preview. Small text is not readable.

## When the user asks to understand something in pictures

Give a diagram and one image, with a few lines of prose beside them:

- A file on disk already shows it: draw that file with the line above, in place of a generated image.
- A flow, a structure or states: write a mermaid diagram in a ` ```mermaid ` fence that starts with `graph TD` or `graph LR`. cs-mermaid draws only `graph` and `flowchart`, so draw states and structure as boxes and arrows too, never `stateDiagram` or `classDiagram`.
- Beside the diagram, show what a diagram cannot, such as how the thing looks or how its parts sit together: if a tool that generates images is available, make one image with one provider. Coloured blocks cannot show small text, so ask for few, large labels. Name that provider in the tool's provider list, because the tool may default to every provider, and give it an absolute output path under `/tmp/` with no spaces or brackets, such as `/tmp/cs-images-picture-espresso-flow`. A relative path is not drawn.

An image model draws what looks plausible and can route a pipe or a signal the wrong way. Before drawing a generated image, open the file the tool reports and compare it with your own explanation and diagram. If it contradicts them, say what is wrong in one line next to it, or leave it out and say why. Then draw the absolute file path the tool reports with the line above. Introduce the image as how the thing looks, and point to the diagram for how it works.

If no such tool is available, draw a diagram and say you have no image tool. Never put secrets, credentials, client data or private file contents in an image description, because the description goes to an outside service; draw a diagram for those.
