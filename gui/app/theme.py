"""Dark theme with neon accents. One QSS string applied app-wide; the few
programmatic colours (verdict text) come from the same palette so nothing
drifts. Contrast is deliberate: text is ~13:1 against the base background,
neon fills carry near-black text (~10:1), never white-on-neon."""

# Base surfaces
BG = "#12141a"          # window
SURFACE = "#1a1d26"     # cards, inputs
SUNKEN = "#0b0d12"      # log panes
BORDER = "#2a2e3d"

# Text
TEXT = "#e8eaf2"
MUTED = "#9aa0b5"
ON_NEON = "#07130e"     # near-black for text on neon fills

# Neon accents
NEON_GREEN = "#00e5a0"  # primary actions
NEON_CYAN = "#22d3ee"   # secondary / outlines
GOOD = "#00e676"
WARN = "#ffb300"
BAD = "#ff5470"

QSS = f"""
QWidget {{
    background: {BG};
    color: {TEXT};
    font-size: 13px;
}}
QMainWindow, QWizard, QDialog {{ background: {BG}; }}

QLabel {{ background: transparent; }}

QGroupBox {{
    background: {SURFACE};
    border: 1px solid {BORDER};
    border-radius: 10px;
    margin-top: 14px;
    padding: 10px 12px 8px 12px;
}}
QGroupBox::title {{
    subcontrol-origin: margin;
    left: 10px;
    padding: 0 6px;
    color: {NEON_CYAN};
    font-weight: bold;
    letter-spacing: 0.5px;
}}

QLineEdit, QComboBox, QPlainTextEdit {{
    background: {SUNKEN};
    border: 1px solid {BORDER};
    border-radius: 6px;
    padding: 6px 8px;
    selection-background-color: {NEON_CYAN};
    selection-color: {ON_NEON};
}}
QLineEdit:focus, QComboBox:focus {{ border: 1px solid {NEON_CYAN}; }}
QComboBox::drop-down {{ border: none; width: 22px; }}
QComboBox QAbstractItemView {{
    background: {SURFACE};
    border: 1px solid {BORDER};
    selection-background-color: {NEON_CYAN};
    selection-color: {ON_NEON};
}}

QPushButton {{
    background: transparent;
    color: {NEON_CYAN};
    border: 1px solid {NEON_CYAN};
    border-radius: 7px;
    padding: 6px 16px;
    font-weight: 600;
}}
QPushButton:hover {{ background: rgba(34, 211, 238, 0.14); }}
QPushButton:pressed {{ background: rgba(34, 211, 238, 0.28); }}
QPushButton:disabled {{
    color: {MUTED};
    border-color: {BORDER};
    background: transparent;
}}

QPushButton#primary {{
    background: {NEON_GREEN};
    color: {ON_NEON};
    border: 1px solid {NEON_GREEN};
}}
QPushButton#primary:hover {{ background: #3cffc0; border-color: #3cffc0; }}
QPushButton#primary:pressed {{ background: #00c489; }}
QPushButton#primary:disabled {{
    background: {BORDER};
    color: {MUTED};
    border-color: {BORDER};
}}

QPushButton#danger {{
    background: transparent;
    color: {BAD};
    border: 1px solid {BAD};
}}
QPushButton#danger:hover {{ background: rgba(255, 84, 112, 0.16); }}
QPushButton#danger:pressed {{ background: rgba(255, 84, 112, 0.30); }}

QCheckBox, QRadioButton {{ spacing: 8px; background: transparent; }}
QCheckBox::indicator, QRadioButton::indicator {{
    width: 15px; height: 15px;
    border: 1px solid {BORDER};
    background: {SUNKEN};
}}
QCheckBox::indicator {{ border-radius: 4px; }}
QRadioButton::indicator {{ border-radius: 8px; }}
QCheckBox::indicator:checked, QRadioButton::indicator:checked {{
    background: {NEON_GREEN};
    border: 1px solid {NEON_GREEN};
}}

QToolBar {{
    background: {SURFACE};
    border-bottom: 1px solid {BORDER};
    padding: 6px;
    spacing: 8px;
}}

QScrollArea {{ border: none; }}
QScrollBar:vertical {{
    background: {BG}; width: 10px; margin: 0;
}}
QScrollBar::handle:vertical {{
    background: {BORDER}; border-radius: 5px; min-height: 30px;
}}
QScrollBar::handle:vertical:hover {{ background: {NEON_CYAN}; }}
QScrollBar::add-line, QScrollBar::sub-line {{ height: 0; }}

QSplitter::handle {{ background: {BORDER}; height: 2px; }}

QWizard QFrame[frameShape="4"] {{ color: {BORDER}; }}
"""
