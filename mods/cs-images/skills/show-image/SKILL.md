---
name: show-image
description: This skill should be used when the user asks to see, show or display an image, screenshot, photo or chart that is a file on disk.
---

Write one line holding only `![short name](/absolute/path)`, outside any code block. Use an absolute path with no spaces in it. Replace `short name` with a brief name for the picture.

For example, write this line on its own:

![short name](/absolute/path.png)

Supported formats are png, jpg, jpeg, gif, heic, webp, tiff, bmp.

cs-images draws real pixels where the terminal allows them and coloured blocks elsewhere. With blocks, the picture is a preview. Small text is not readable.
