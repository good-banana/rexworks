---
title: Every element
tags: fixture
---

# Heading one

Plain text with **bold**, *italic*, ***both***, ~~struck~~, [a link](https://example.com), `inline code`,
<kbd>Cmd</kbd>+<kbd>C</kbd>, H<sub>2</sub>O, x<sup>2</sup>, <mark>marked</mark>, <ins>inserted</ins> and
<abbr title="HyperText">HTML</abbr>. A footnote reference.[^note]

## Heading two

> A quote with a second line
> that keeps going.

> [!NOTE]
> Useful information.

> [!TIP]
> Helpful advice.

> [!IMPORTANT]
> Key information.

> [!WARNING]
> Urgent information.

> [!CAUTION]
> Risky outcome.

1. First
2. Second
   - Nested bullet
     - Deeper bullet

- [x] Done task
- [ ] Open task

```python
import os

def main(path: str) -> int:
    # Count entries
    return len(os.listdir(path)) + 42
```

```
plain code block without a language
```

```swift
let veryLongLine = "This line is deliberately much longer than the page so the code block becomes a horizontal scroll region"
```

| Name | Value | Notes |
| --- | ---: | :---: |
| alpha | 1 | first |
| beta | 2 | second |
| gamma | 3 | third |

<details>
<summary>Closed details</summary>

Hidden body.

</details>

<details open>
<summary>Open details</summary>

Visible body.

</details>

![missing image](missing.png)

---

> שלום עולם, זהו ציטוט מימין לשמאל.

[^note]: The footnote text.
