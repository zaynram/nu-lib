# Run a command in a pseudo-terminal and answer its prompts, for the pman `bump-nu` tests.
#
# Usage: python3 -I pty.py TIMEOUT [EXPECT SEND]... -- COMMAND [ARG]...
# For each pair, waits until the regex EXPECT appears in the output (after the previous match), then types SEND
# (Python escapes such as \r and \x1b are decoded). Prints the whole output and exits with the command's status,
# or 124 when TIMEOUT seconds pass first.
import codecs
import fcntl
import os
import pty
import re
import select
import struct
import sys
import termios
import time

args = sys.argv[1:]
sep = args.index("--")
deadline = time.monotonic() + float(args[0])
pairs = list(zip(args[1:sep:2], args[2:sep:2]))
command = args[sep + 1:]

pid, fd = pty.fork()
if pid == 0:
    os.execvp(command[0], command)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))

output = b""


def read_some():
    """Read what is available; False once the command has closed the terminal."""
    global output
    if time.monotonic() > deadline:
        os.kill(pid, 9)
        sys.stdout.buffer.write(output)
        sys.exit(124)
    ready, _, _ = select.select([fd], [], [], 0.05)
    if not ready:
        return True
    try:
        data = os.read(fd, 4096)
    except OSError:
        return False
    output += data
    return bool(data)


open_ = True
position = 0
for expect, send in pairs:
    pattern = re.compile(expect.encode())
    match = pattern.search(output, position)
    while open_ and match is None:
        open_ = read_some()
        match = pattern.search(output, position)
    if match is None:
        break
    position = match.end()
    os.write(fd, codecs.decode(send, "unicode_escape").encode())
while open_:
    open_ = read_some()
_, status = os.waitpid(pid, 0)
sys.stdout.buffer.write(output)
sys.exit(os.waitstatus_to_exitcode(status))
