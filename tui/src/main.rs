// ABOUTME: Entry point that initializes the terminal, runs the event loop, and handles exit
// ABOUTME: Communicates the selected session name to the calling bash script via stdout

use std::io::{self, BufWriter, IsTerminal};

use crossterm::event::{self, DisableMouseCapture, EnableMouseCapture, Event, KeyEventKind};
use crossterm::terminal::{self, EnterAlternateScreen, LeaveAlternateScreen};
use crossterm::ExecutableCommand;
use ratatui::backend::CrosstermBackend;
use ratatui::Terminal;

mod app;
mod session;
mod theme;
mod ui;

type Tui = Terminal<CrosstermBackend<BufWriter<io::Stderr>>>;

fn main() {
    if !io::stderr().is_terminal() {
        eprintln!("cs-tui requires an interactive terminal");
        std::process::exit(1);
    }

    let sessions = session::scan_sessions();
    if sessions.is_empty() {
        eprintln!("No sessions found. Create one with: cs <name>");
        return;
    }

    let mut app = app::App::new(sessions);

    let mut terminal = init_terminal().expect("failed to initialize terminal");
    let result = run_event_loop(&mut app, &mut terminal);
    restore_terminal().expect("failed to restore terminal");

    match result {
        Ok(app::Action::Open(name)) => {
            println!("{}", name);
        }
        Ok(app::Action::ForceOpen(name)) => {
            println!("{}", name);
            println!("--force");
        }
        Ok(app::Action::Quit) | Ok(app::Action::None) => {}
        Err(e) => {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
    }
}

fn init_terminal() -> io::Result<Tui> {
    terminal::enable_raw_mode()?;
    let mut stderr = io::stderr();
    stderr.execute(EnterAlternateScreen)?;
    stderr.execute(EnableMouseCapture)?;
    let backend = CrosstermBackend::new(BufWriter::new(io::stderr()));
    let terminal = Terminal::new(backend)?;
    Ok(terminal)
}

fn restore_terminal() -> io::Result<()> {
    let mut stderr = io::stderr();
    stderr.execute(DisableMouseCapture)?;
    stderr.execute(LeaveAlternateScreen)?;
    terminal::disable_raw_mode()?;
    Ok(())
}

fn run_event_loop(app: &mut app::App, terminal: &mut Tui) -> io::Result<app::Action> {
    loop {
        terminal.draw(|frame| ui::render(app, frame))?;

        match event::read()? {
            Event::Key(key) => {
                if key.kind == KeyEventKind::Press {
                    let action = app.handle_key(key);
                    match action {
                        app::Action::Quit | app::Action::Open(_) | app::Action::ForceOpen(_) => return Ok(action),
                        app::Action::None => {}
                    }
                }
            }
            Event::Mouse(mouse) => {
                let action = app.handle_mouse(mouse);
                match action {
                    app::Action::Quit | app::Action::Open(_) | app::Action::ForceOpen(_) => return Ok(action),
                    app::Action::None => {}
                }
            }
            _ => {}
        }
    }
}
