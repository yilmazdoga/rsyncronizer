"""Rsyncronizer entry point.

`rsyncronizer --self-check` never touches Qt widgets: it materializes the
engine, runs status.sh --porcelain, prints a summary and exits with the
status exit code — usable over ssh on a machine with no display.
"""

from __future__ import annotations

import os
import sys


def main() -> int:
    # Presentational only: every engine child this app spawns gets a pty and
    # looks manual+interactive, so without this the terminal support reminder
    # would land in the streamed consoles. The app shows its own dialog.
    os.environ["RBS_NO_SUPPORT_NAG"] = "1"

    if "--self-check" in sys.argv:
        from . import engine
        return engine.self_check()

    from PySide6.QtWidgets import (
        QApplication,
        QLabel,
        QMainWindow,
        QPushButton,
        QSplitter,
        QToolBar,
        QVBoxLayout,
        QWidget,
    )
    from PySide6.QtCore import Qt
    from PySide6.QtGui import QIcon

    from . import engine
    from .dialogs import ManageRemotesDialog, SupportDialog
    from .run_panel import RunPanel
    from .status_view import StatusView
    from .theme import QSS
    from .version import app_version
    from .wizard import BackupWizard

    app = QApplication(sys.argv)
    app.setApplicationName("Rsyncronizer")
    app.setStyleSheet(QSS)
    # Frozen: datas put them at _MEIPASS/assets; dev: gui/assets next to app/.
    if getattr(sys, "frozen", False):
        assets_dir = os.path.join(sys._MEIPASS, "assets")
    else:
        assets_dir = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets"
        )
    icon_path = os.path.join(assets_dir, "icon-256.png")
    if os.path.isfile(icon_path):
        app.setWindowIcon(QIcon(icon_path))

    engine.materialize()

    win = QMainWindow()
    win.setWindowTitle(f"Rsyncronizer  v{app_version()}")
    win.resize(860, 640)

    run_panel = RunPanel()
    view = StatusView(run_panel)

    splitter = QSplitter(Qt.Vertical)
    splitter.addWidget(view)
    splitter.addWidget(run_panel)
    splitter.setStretchFactor(0, 4)
    splitter.setStretchFactor(1, 1)

    central = QWidget()
    lay = QVBoxLayout(central)
    missing = engine.check_tools()
    if missing:
        from .theme import BAD, ON_NEON

        banner = QLabel(
            f"Missing required tools: {', '.join(missing)} — install them first "
            f"({'brew/apt' if 'rsync' in missing else 'openssh'})."
        )
        banner.setStyleSheet(
            f"background: {BAD}; color: {ON_NEON}; padding: 6px; "
            "border-radius: 6px; font-weight: bold;"
        )
        lay.addWidget(banner)
    lay.addWidget(splitter)
    win.setCentralWidget(central)

    toolbar = QToolBar()
    toolbar.setMovable(False)
    win.addToolBar(toolbar)

    def new_backup():
        wiz = BackupWizard(win)
        view.modal_guard(True)
        wiz.exec()
        view.modal_guard(False)
        view.refresh()

    def manage_remotes():
        dlg = ManageRemotesDialog(win)
        view.modal_guard(True)
        dlg.exec()
        view.modal_guard(False)
        if dlg.changed:
            view.refresh()

    new_btn = QPushButton("New backup")
    new_btn.setObjectName("primary")
    new_btn.clicked.connect(new_backup)
    server_btn = QPushButton("Manage Remote Control")
    server_btn.clicked.connect(manage_remotes)
    ignore_btn = QPushButton("Global Ignore Rules")
    ignore_btn.clicked.connect(lambda: view.open_ignores())
    toolbar.addWidget(new_btn)
    toolbar.addWidget(ignore_btn)
    toolbar.addWidget(server_btn)

    # --- self-update: check on startup, button appears on the RIGHT --------
    from PySide6.QtCore import QThread, Signal

    from . import updater
    from .dialogs import UpdateDialog
    from .version import app_version as _ver

    updater.cleanup_leftovers()
    spacer = QWidget()
    from PySide6.QtWidgets import QSizePolicy

    spacer.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Preferred)
    toolbar.addWidget(spacer)

    # A small coffee icon, no text; it opens the support dialog (which holds
    # the actual "Buy me a coffee" action) rather than jumping to the page.
    def show_support_dialog():
        dlg = SupportDialog(win)
        view.modal_guard(True)
        dlg.exec()
        view.modal_guard(False)

    coffee_btn = QPushButton()
    coffee_icon = os.path.join(assets_dir, "coffee.png")
    if os.path.isfile(coffee_icon):
        from PySide6.QtCore import QSize

        coffee_btn.setIcon(QIcon(coffee_icon))
        coffee_btn.setIconSize(QSize(20, 20))
    else:  # icon missing (unexpected): still give the button a face
        coffee_btn.setText("☕")
    coffee_btn.setToolTip("Support Rsyncronizer")
    coffee_btn.setFixedWidth(36)
    coffee_btn.clicked.connect(show_support_dialog)
    toolbar.addWidget(coffee_btn)

    class UpdateCheck(QThread):
        found = Signal(object)

        def run(self):
            info = updater.check_latest(_ver())
            if info:
                self.found.emit(info)

    def show_update_button(info):
        btn = QPushButton("Update Available")
        btn.setObjectName("primary")

        def run_update():
            dlg = UpdateDialog(info, _ver(), win)
            view.modal_guard(True)
            dlg.exec()
            view.modal_guard(False)

        btn.clicked.connect(run_update)
        toolbar.addWidget(btn)

    checker = UpdateCheck(win)
    checker.found.connect(show_update_button)
    checker.start()

    win.show()

    # Counts accumulated by scheduled runs surface here, once the window is
    # painted. Runs finished inside the app trigger the same dialog via
    # StatusView._maybe_support_nag.
    def startup_support_check():
        if engine.support_due():
            show_support_dialog()

    from PySide6.QtCore import QTimer

    QTimer.singleShot(0, startup_support_check)
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
