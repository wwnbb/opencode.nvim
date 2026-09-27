"""Attach a real Neovim line-grid UI and capture its rendered cells as PNG.

Requires msgpack and Pillow in the Python environment. No personal Neovim config
or terminal is used. Lua scenarios request captures with opencode_screenshot.
"""
import os
from pathlib import Path
import select
import subprocess
import time

import msgpack
from PIL import Image, ImageDraw, ImageFont


def run(repo, script, env, output):
    command = ["nvim", "--embed", "--headless", "--noplugin", "-n", "-i", "NONE", "-u", str(repo / "tests/minimal_init.lua")]
    process = subprocess.Popen(command, cwd=repo, env=dict(env, OPENCODE_V2_ATTACHED_UI="1"),
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    unpacker = msgpack.Unpacker(raw=False, strict_map_key=False)
    grids, highlights, defaults = {}, {}, {"foreground": 0xD8DEE9, "background": 0x101318}
    errors, captures, sequence = [], [], 0
    acknowledged_prompt = False

    def send(method, params):
        nonlocal sequence
        sequence += 1
        process.stdin.write(msgpack.packb([0, sequence, method, params], use_bin_type=True)); process.stdin.flush()
        return sequence

    def screenshot(name):
        grid = grids.get(1)
        assert grid, "No root Neovim grid"
        cell_width, cell_height = 10, 21
        font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 16)
        canvas = Image.new("RGB", (len(grid[0]) * cell_width, len(grid) * cell_height))
        draw = ImageDraw.Draw(canvas)
        def rgb(value): return ((value >> 16) & 255, (value >> 8) & 255, value & 255)
        text_cells = []
        for row, cells in enumerate(grid):
            for col, (char, style) in enumerate(cells):
                hl = highlights.get(style, {})
                fg, bg = hl.get("foreground", defaults["foreground"]), hl.get("background", defaults["background"])
                if hl.get("reverse"): fg, bg = bg, fg
                x, y = col * cell_width, row * cell_height
                draw.rectangle((x, y, x + cell_width - 1, y + cell_height - 1), fill=rgb(bg))
                if char: text_cells.append((x, y, char, rgb(fg)))
        for x, y, char, fg in text_cells: draw.text((x, y), char, fill=fg, font=font)
        target = output / (name + ".png"); canvas.save(target); captures.append(str(target))
        (output / (name + ".txt")).write_text("\n".join("".join(char for char, _ in row) for row in grid))

    def redraw(changes):
        for kind, *values in changes:
            for args in values:
                if kind == "grid_resize":
                    grid, width, height = args; grids[grid] = [[(" ", 0) for _ in range(width)] for _ in range(height)]
                elif kind == "grid_clear":
                    grid = grids[args[0]]
                    for row in grid: row[:] = [(" ", 0)] * len(row)
                elif kind == "grid_line":
                    grid_id, row, col, cells = args[:4]; grid, style = grids[grid_id], 0
                    for cell in cells:
                        char = cell[0]
                        if len(cell) > 1: style = cell[1]
                        count = cell[2] if len(cell) > 2 else 1
                        for _ in range(count): grid[row][col] = (char, style); col += 1
                elif kind == "grid_scroll":
                    grid_id, top, bottom, left, right, rows, cols = args
                    grid = grids[grid_id]; previous = [row[:] for row in grid]
                    for row in range(top, bottom):
                        for col in range(left, right):
                            source_row, source_col = row + rows, col + cols
                            if top <= source_row < bottom and left <= source_col < right:
                                grid[row][col] = previous[source_row][source_col]
                            else: grid[row][col] = (" ", 0)
                elif kind == "hl_attr_define": highlights[args[0]] = args[1]
                elif kind == "default_colors_set":
                    if args[0] >= 0: defaults["foreground"] = args[0]
                    if args[1] >= 0: defaults["background"] = args[1]

    try:
        attach = send("nvim_ui_attach", [120, 40, {"rgb": True, "ext_linegrid": True}])
        execution = None
        deadline = time.monotonic() + 330
        while time.monotonic() < deadline:
            ready = select.select([process.stdout, process.stderr], [], [], 1)[0]
            for file in ready:
                chunk = os.read(file.fileno(), 65536)
                if file == process.stderr:
                    if chunk: errors.append(chunk.decode(errors="replace"))
                    continue
                if not chunk: continue
                unpacker.feed(chunk)
                for message in unpacker:
                    if message[0] == 2:
                        if message[1] == "redraw":
                            redraw(message[2])
                            # A native UI must acknowledge Neovim's message pager.
                            # This is not a permission/form decision.
                            screen = "\n".join("".join(char for char, _ in row) for row in grids.get(1, []))
                            hit_enter = "Press ENTER or type command to continue" in screen
                            if hit_enter and not acknowledged_prompt: send("nvim_input", ["\r"])
                            acknowledged_prompt = hit_enter
                        elif message[1] == "opencode_screenshot": screenshot(message[2][0])
                        elif message[1] == "opencode_resize": send("nvim_ui_try_resize", message[2])
                    elif message[0] == 1:
                        if message[2] is not None: raise RuntimeError(str(message[2]))
                        if message[1] == attach:
                            execution = send("nvim_exec_lua", ["dofile(...)", [str(repo / "tests/runtime" / script)]])
                        elif message[1] == execution:
                            send("nvim_command", ["qa!"])
            if process.poll() is not None:
                assert captures, "Scenario produced no UI captures"
                return subprocess.CompletedProcess(command, process.returncode, "Captured native UI: " + ", ".join(captures), "".join(errors))
        raise TimeoutError("Attached Neovim UI timeout")
    except BaseException:
        if grids.get(1): screenshot("failure-state")
        raise
    finally:
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=5)
