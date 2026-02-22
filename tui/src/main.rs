// ABOUTME: Entry point that initializes the terminal, runs the event loop, and handles exit
// ABOUTME: Communicates the selected session name to the calling bash script via stdout

use std::io::{self, IsTerminal};

use crossterm::event::{self, Event, KeyEventKind};

mod app;
mod session;
mod theme;
mod ui;

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
    let mut terminal = ratatui::init();

    let result = run_event_loop(&mut app, &mut terminal);

    ratatui::restore();

    match result {
        Ok(app::Action::Open(name)) => {
            println!("{}", name);
        }
        Ok(app::Action::Quit) | Ok(app::Action::None) => {}
        Err(e) => {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
    }
}

fn run_event_loop(
    app: &mut app::App,
    terminal: &mut ratatui::DefaultTerminal,
) -> io::Result<app::Action> {
    loop {
        terminal.draw(|frame| ui::render(app, frame))?;

        if let Event::Key(key) = event::read()? {
            if key.kind == KeyEventKind::Press {
                let action = app.handle_key(key);
                match action {
                    app::Action::Quit | app::Action::Open(_) => return Ok(action),
                    app::Action::None => {}
                }
            }
        }
    }
}
