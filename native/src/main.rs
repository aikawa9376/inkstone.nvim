use cairo::{Context, Format, ImageSurface};
use pangocairo::pango::{FontDescription, Style, Weight, SCALE};
use serde::Deserialize;
use std::io::{self, Read, Write};

const MAX_INPUT: u64 = 1_048_576;
const MAX_PIXELS: u64 = 16_777_216;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    font: String,
    cell_width: u32,
    cell_height: u32,
    columns: u32,
    scale: u32,
    ratio: f64,
    lines: Vec<Vec<Run>>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Run {
    text: String,
    cells: u32,
    #[serde(default = "white")]
    fg: u32,
    bg: Option<u32>,
    #[serde(default)]
    bold: bool,
    #[serde(default)]
    italic: bool,
    #[serde(default)]
    underline: bool,
    #[serde(default)]
    strikethrough: bool,
}

fn white() -> u32 {
    0xffffff
}

impl Request {
    fn dimensions(&self) -> Result<(i32, i32), String> {
        if self.font.is_empty() || self.font.len() > 512 || self.font.contains('\0') {
            return Err("font must be a nonempty family name (at most 512 bytes)".into());
        }
        if !(1..=256).contains(&self.cell_width)
            || !(1..=256).contains(&self.cell_height)
            || !(1..=256).contains(&self.columns)
            || !(1..=4).contains(&self.scale)
            || !self.ratio.is_finite()
            || !(0.5..=4.0).contains(&self.ratio)
            || self.lines.is_empty()
            || self.lines.len() * self.scale as usize > 256
        {
            return Err("invalid or excessive raster dimensions".into());
        }
        for line in &self.lines {
            let mut columns = 0u64;
            for run in line {
                if run.cells == 0
                    || run.text.chars().any(char::is_control)
                    || run.fg > 0xffffff
                    || run.bg.is_some_and(|bg| bg > 0xffffff)
                {
                    return Err("invalid text run, color or cell advance".into());
                }
                columns += u64::from(run.cells);
            }
            if columns > u64::from(self.columns) {
                return Err("line advances exceed the image columns".into());
            }
        }
        let width = u64::from(self.columns) * u64::from(self.cell_width);
        let height = self.lines.len() as u64 * u64::from(self.scale) * u64::from(self.cell_height);
        if width * height > MAX_PIXELS || width > i32::MAX as u64 || height > i32::MAX as u64 {
            return Err("image exceeds the pixel budget".into());
        }
        Ok((width as i32, height as i32))
    }
}

fn color(cr: &Context, rgb: u32) {
    cr.set_source_rgb(
        f64::from(rgb >> 16) / 255.,
        f64::from((rgb >> 8) & 255) / 255.,
        f64::from(rgb & 255) / 255.,
    );
}

fn raster(request: &Request) -> Result<ImageSurface, Box<dyn std::error::Error>> {
    let (width, height) = request.dimensions()?;
    let surface = ImageSurface::create(Format::ARgb32, width, height)?;
    let cr = Context::new(&surface)?;
    let layout = pangocairo::functions::create_layout(&cr);
    layout.set_single_paragraph_mode(true);
    let mut font = FontDescription::new();
    font.set_family(&request.font);
    font.set_absolute_size(16. * f64::from(SCALE));
    layout.set_font_description(Some(&font));
    layout.set_text("M");
    let (mw, mh) = layout.pixel_size();
    // Calibrate to one terminal cell rather than guessing a point size or DPI.
    let fit = (f64::from(request.cell_width) / f64::from(mw.max(1)))
        .min(f64::from(request.cell_height) / f64::from(mh.max(1)));
    font.set_absolute_size(16. * fit * request.ratio * f64::from(SCALE));
    let row_height = f64::from(request.cell_height * request.scale);
    for (row, runs) in request.lines.iter().enumerate() {
        let mut x = 0.;
        let top = row as f64 * row_height;
        for run in runs {
            let advance = f64::from(run.cells * request.cell_width);
            cr.save()?;
            cr.rectangle(x, top, advance, row_height);
            cr.clip();
            if let Some(bg) = run.bg {
                color(&cr, bg);
                cr.paint()?;
            }
            font.set_weight(if run.bold {
                Weight::Bold
            } else {
                Weight::Normal
            });
            font.set_style(if run.italic {
                Style::Italic
            } else {
                Style::Normal
            });
            layout.set_font_description(Some(&font));
            layout.set_text(&run.text);
            let (ink, logical) = layout.pixel_extents();
            let natural_width = (logical.width().max(ink.x() + ink.width())).max(1);
            // Fallback CJK fonts can have wider metrics than the primary font.
            // Fit an overwide run into its reserved cells, without changing text.
            let stretch = (advance / f64::from(natural_width)).min(1.);
            let y = top + (row_height - f64::from(logical.height())) / 2. - f64::from(logical.y());
            color(&cr, run.fg);
            cr.translate(x, y);
            cr.scale(stretch, 1.);
            cr.move_to(0., 0.);
            pangocairo::functions::show_layout(&cr, &layout);
            cr.restore()?;
            if run.underline || run.strikethrough {
                color(&cr, run.fg);
                cr.set_line_width((request.ratio / 1.5).max(1.));
                for enabled in [run.underline, run.strikethrough].iter().enumerate() {
                    if *enabled.1 {
                        let y = top + row_height * if enabled.0 == 0 { 0.83 } else { 0.5 };
                        cr.move_to(x, y);
                        cr.line_to(x + advance, y);
                        cr.stroke()?;
                    }
                }
            }
            x += advance;
        }
    }
    surface.flush();
    Ok(surface)
}

fn main() {
    if let Err(error) = run() {
        eprintln!("inkstone-raster: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    match std::env::args().nth(1).as_deref() {
        Some("--version") => {
            println!("inkstone-raster {}", env!("CARGO_PKG_VERSION"));
            return Ok(());
        }
        Some("--help") => {
            println!("Read one JSON heading request from stdin; write a PNG to stdout.\nUses Pango/Cairo and system fonts; never writes terminal escape sequences.");
            return Ok(());
        }
        Some(_) => return Err("unknown argument (use --help)".into()),
        None => {}
    }
    let mut input = Vec::new();
    io::stdin().take(MAX_INPUT + 1).read_to_end(&mut input)?;
    if input.len() as u64 > MAX_INPUT {
        return Err("request exceeds 1 MiB".into());
    }
    let request: Request = serde_json::from_slice(&input)?;
    let surface = raster(&request)?;
    let mut output = io::BufWriter::new(io::stdout().lock());
    surface.write_to_png(&mut output)?;
    output.flush()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request() -> Request {
        serde_json::from_str(r#"{"font":"monospace","cell_width":12,"cell_height":24,"columns":20,"scale":2,"ratio":1.5,"lines":[[{"text":"日本語 café 👩‍💻","cells":20,"fg":1193046,"bold":true}]]}"#).unwrap()
    }

    #[test]
    fn renders_styled_unicode_to_a_nonempty_transparent_png() {
        let image = raster(&request()).unwrap();
        assert_eq!((image.width(), image.height()), (240, 48));
        image
            .with_data(|pixels| {
                let (pixels, _) = pixels.as_chunks::<4>();
                let alpha = if cfg!(target_endian = "little") { 3 } else { 0 };
                assert!(pixels.iter().any(|pixel| pixel[alpha] > 0));
                assert!(pixels.iter().any(|pixel| pixel[alpha] == 0));
            })
            .unwrap();
        let mut png = Vec::new();
        image.write_to_png(&mut png).unwrap();
        assert_eq!(&png[..8], b"\x89PNG\r\n\x1a\n");
    }

    #[test]
    fn rejects_invalid_dimensions_controls_and_excessive_advances() {
        let mut input = request();
        input.columns = 0;
        assert!(input.dimensions().is_err());
        input.columns = 256;
        input.lines[0][0].text.push('\x1b');
        assert!(input.dimensions().is_err());
        input.lines[0][0].text = "heading".into();
        input.lines[0][0].cells = 257;
        assert!(input.dimensions().is_err());
        input.lines[0][0].cells = 20;
        input.cell_width = 256;
        input.cell_height = 256;
        input.lines = (0..64).map(|_| Vec::new()).collect();
        assert!(input.dimensions().is_err());
    }
}
