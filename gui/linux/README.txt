Rsyncronizer (Linux x86_64)

Install for the current user (no root needed):

    ./install.sh

Or run it in place:

    ./rsyncronizer/rsyncronizer

Needs rsync and ssh on PATH (sudo apt install rsync openssh-client), and
glibc 2.35+ (Ubuntu 22.04 or newer).

Headless sanity check over ssh:

    QT_QPA_PLATFORM=offscreen ./rsyncronizer/rsyncronizer --self-check
