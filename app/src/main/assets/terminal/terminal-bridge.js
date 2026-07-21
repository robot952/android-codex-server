(function () {
    'use strict';

    const terminal = new Terminal({
        fontSize: 14,
        fontFamily: "'Droid Sans Mono', 'Noto Sans Mono', monospace",
        theme: {
            background: '#000000',
            foreground: '#00ff00',
            cursor: '#00ff00',
            cursorAccent: '#000000',
            selectionBackground: '#2f5f2f'
        },
        cursorBlink: true,
        scrollback: 10000,
        convertEol: false,
        smoothScrollDuration: 0
    });
    const fitAddon = new FitAddon.FitAddon();
    terminal.loadAddon(fitAddon);
    terminal.open(document.getElementById('terminal'));

    let resizeTimer = null;
    let reportedColumns = 0;
    let reportedRows = 0;
    function fitTerminal() {
        try {
            fitAddon.fit();
            if (terminal.cols !== reportedColumns || terminal.rows !== reportedRows) {
                reportedColumns = terminal.cols;
                reportedRows = terminal.rows;
                Android.onResize(terminal.cols, terminal.rows);
            }
        } catch (_) {
            // A zero-sized WebView can briefly occur while hiding the overlay.
        }
    }

    terminal.onData(function (data) {
        Android.sendData(data);
    });
    terminal.onSelectionChange(function () {
        const selection = terminal.getSelection();
        if (selection) Android.onCopy(selection);
    });
    window.writeBase64 = function (encoded, token) {
        try {
            const binary = atob(encoded);
            const bytes = new Uint8Array(binary.length);
            for (let index = 0; index < binary.length; index += 1) {
                bytes[index] = binary.charCodeAt(index);
            }
            terminal.write(bytes, function () {
                Android.onWriteComplete(token, true);
            });
        } catch (_) {
            Android.onWriteComplete(token, false);
        }
    };
    window.resetTerminal = function () {
        terminal.reset();
        fitTerminal();
    };
    window.focusTerminal = function () {
        terminal.focus();
    };
    window.enterCopyMode = function () {
        const screen = document.querySelector('.xterm-screen');
        if (!screen) return;
        let startColumn = 0;
        let startRow = 0;

        function position(touch) {
            const bounds = screen.getBoundingClientRect();
            const cellWidth = bounds.width / terminal.cols;
            const cellHeight = bounds.height / terminal.rows;
            return {
                column: Math.max(0, Math.min(Math.floor((touch.clientX - bounds.left) / cellWidth), terminal.cols - 1)),
                row: Math.max(0, Math.min(Math.floor((touch.clientY - bounds.top) / cellHeight), terminal.rows - 1))
            };
        }
        function stop() {
            screen.removeEventListener('touchstart', start);
            screen.removeEventListener('touchmove', move);
            screen.removeEventListener('touchend', end);
            screen.removeEventListener('touchcancel', end);
        }
        function start(event) {
            const point = position(event.touches[0]);
            startColumn = point.column;
            startRow = point.row;
            terminal.select(startColumn, startRow + terminal.buffer.active.viewportY, 1);
            event.preventDefault();
        }
        function move(event) {
            const point = position(event.touches[0]);
            let firstRow = startRow;
            let firstColumn = startColumn;
            let lastRow = point.row;
            let lastColumn = point.column;
            if (lastRow < firstRow || (lastRow === firstRow && lastColumn < firstColumn)) {
                firstRow = point.row;
                firstColumn = point.column;
                lastRow = startRow;
                lastColumn = startColumn;
            }
            const length = (lastRow - firstRow) * terminal.cols + (lastColumn - firstColumn) + 1;
            terminal.select(firstColumn, firstRow + terminal.buffer.active.viewportY, length);
            event.preventDefault();
        }
        function end() {
            const selection = terminal.getSelection();
            if (selection) Android.onCopy(selection);
            terminal.clearSelection();
            stop();
        }

        screen.addEventListener('touchstart', start, {passive: false});
        screen.addEventListener('touchmove', move, {passive: false});
        screen.addEventListener('touchend', end);
        screen.addEventListener('touchcancel', end);
    };

    document.addEventListener('contextmenu', function (event) {
        event.preventDefault();
    });
    new ResizeObserver(function () {
        clearTimeout(resizeTimer);
        resizeTimer = setTimeout(fitTerminal, 30);
    }).observe(document.getElementById('terminal'));

    requestAnimationFrame(function () {
        fitTerminal();
        terminal.focus();
        Android.onReady();
    });
}());
