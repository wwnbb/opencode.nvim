"""Real URI/inline attachments with Unicode names and persisted mentions."""
import base64
import struct
import time
import zlib


def red_png():
    """A generated 2x2 red test image; no personal clipboard data."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    image = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0))
    image += chunk(b"IDAT", zlib.compress((b"\x00" + b"\xff\x00\x00" * 2) * 2)) + chunk(b"IEND", b"")
    return image


def run(request, save, prefix, project):
    path = project / "текст with %#.txt"
    path.write_text("ATTACHMENT_V2_OK\nsecond line\n", encoding="utf-8")
    image = red_png()
    png = base64.b64encode(image).decode()
    text = "猫🙂é\n[File 1] [Image 1] @build\nRead the attached text and reply with its first line exactly. Do not call tools or delegate tasks."
    # Native TUI uses display-cell offsets, including one cell per newline.
    file_mention = {"start": 6, "end": 14, "text": "[File 1]"}
    image_mention = {"start": 15, "end": 24, "text": "[Image 1]"}
    agent_mention = {"start": 25, "end": 31, "text": "@build"}
    body = {"text": text, "delivery": "queue", "files": [
        {"uri": path.as_uri(), "name": path.name, "mention": file_mention},
        {"uri": "data:image/png;base64," + png, "name": "clipboard.png", "mention": image_mention},
    ], "agents": [{"name": "build", "mention": agent_mention}]}
    code, admission = request("POST", prefix + "/prompt", body)
    save("attachments-admission.json", {"status": code, "response": admission})
    assert code == 200, admission
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        code, history = request("GET", prefix + "/message")
        assert code == 200, history
        if any(m["type"] == "idle" for m in history["data"]):
            break
        time.sleep(0.25)
    else:
        raise AssertionError("Attachment response timeout")
    save("attachments-history.json", history)
    user = next(m for m in history["data"] if m["type"] == "user")
    assert user["text"] == text, user
    assert base64.b64decode(user["files"][0]["data"]).decode("utf-8") == path.read_text(), user
    assert user["files"][0]["mention"] == file_mention, user
    assert user["files"][1]["data"] == png and user["files"][1]["mime"] == "image/png", user
    assert user["files"][1]["mention"] == image_mention and user["agents"][0]["mention"] == agent_mention, user
    assert any(c.get("type") == "text" and "ATTACHMENT_V2_OK" in c.get("text", "")
               for m in history["data"] for c in m.get("content", [])), history
