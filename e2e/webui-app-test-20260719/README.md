# RelayOps WebUI

A responsive server operations dashboard built with plain HTML, CSS, and JavaScript. It has no runtime dependencies, build step, or external assets.

## Features

- Responsive desktop, tablet, and mobile layouts
- Infrastructure health and resource metrics
- Interactive CPU, memory, and network performance chart
- Active incident list with feedback notifications
- Searchable server fleet table
- Mobile navigation drawer
- Functional deployment dialog with form validation
- Keyboard shortcut (`Cmd/Ctrl + K`) for infrastructure search
- Reduced-motion support

## Run locally

From this directory:

```bash
python3 -m http.server 8000 --bind 0.0.0.0
```

Open `http://localhost:8000` in a browser.

## Files

- `index.html` contains the semantic page structure.
- `styles.css` contains all layout, visual, and responsive styles.
- `app.js` provides filtering, navigation, chart switching, modal, and notification behavior.
