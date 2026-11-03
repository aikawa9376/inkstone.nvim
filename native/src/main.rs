use cairo::{Context, FontOptions, Format, HintMetrics, HintStyle, ImageSurface};
use pango::{
    AttrColor, AttrInt, AttrList, Attribute, FontDescription, Layout, Style, Underline, Weight,
    SCALE,
};
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
    cells: f64,
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
            let mut columns = 0.;
            for run in line {
                if !run.cells.is_finite()
                    || run.cells <= 0.
                    || run.text.chars().any(char::is_control)
                    || run.fg > 0xffffff
                    || run.bg.is_some_and(|bg| bg > 0xffffff)
                {
                    return Err("invalid text run, color or cell advance".into());
                }
                columns += run.cells;
            }
            if columns > f64::from(self.columns) + 1e-8 {
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

fn attribute(list: &AttrList, value: impl Into<Attribute>, start: u32, end: u32) {
    let mut value = value.into();
    value.set_start_index(start);
    value.set_end_index(end);
    // Coalesce equivalent adjacent attributes so an arbitrary chunk boundary
    // does not split shaping, ligatures or fractional glyph positioning.
    list.change(value);
}

fn line_layout(layout: &Layout, runs: &[Run]) {
    let mut text = String::new();
    let attributes = AttrList::new();
    for run in runs {
        let start = text.len() as u32;
        text.push_str(&run.text);
        let end = text.len() as u32;
        let fg = run.fg;
        attribute(
            &attributes,
            AttrColor::new_foreground(
                ((fg >> 16) as u16) * 257,
                (((fg >> 8) & 255) as u16) * 257,
                ((fg & 255) as u16) * 257,
            ),
            start,
            end,
        );
        if run.bold {
            attribute(&attributes, AttrInt::new_weight(Weight::Bold), start, end);
        }
        if run.italic {
            attribute(&attributes, AttrInt::new_style(Style::Italic), start, end);
        }
        if run.underline {
            attribute(
                &attributes,
                AttrInt::new_underline(Underline::Single),
                start,
                end,
            );
        }
        if run.strikethrough {
            attribute(&attributes, AttrInt::new_strikethrough(true), start, end);
        }
    }
    layout.set_text(&text);
    layout.set_attributes(Some(&attributes));
}

fn raster(request: &Request) -> Result<ImageSurface, Box<dyn std::error::Error>> {
    let (width, height) = request.dimensions()?;
    let surface = ImageSurface::create(Format::ARgb32, width, height)?;
    let cr = Context::new(&surface)?;
    let mut options = FontOptions::new()?;
    options.set_hint_metrics(HintMetrics::Off);
    options.set_hint_style(HintStyle::None);
    cr.set_font_options(&options);
    let layout = pangocairo::functions::create_layout(&cr);
    layout.set_single_paragraph_mode(true);
    layout.context().set_round_glyph_positions(false);
    let mut font = FontDescription::new();
    font.set_family(&request.font);
    font.set_absolute_size(16. * f64::from(SCALE));
    layout.set_font_description(Some(&font));
    layout.set_text("M");
    let (mw, mh) = layout.size();
    // Keep subpixel metrics until rasterization. Height defines the base font;
    // one common horizontal transform matches the terminal's cell proportions.
    let base_scale = f64::from(request.cell_height) * f64::from(SCALE) / f64::from(mh.max(1));
    let cell_scale =
        f64::from(request.cell_width) * f64::from(SCALE) / (f64::from(mw.max(1)) * base_scale);
    font.set_absolute_size(16. * base_scale * request.ratio * f64::from(SCALE));
    layout.set_font_description(Some(&font));
    let row_height = f64::from(request.cell_height * request.scale);
    for (row, runs) in request.lines.iter().enumerate() {
        let top = row as f64 * row_height;
        line_layout(&layout, runs);
        let (_, logical) = layout.extents();
        let natural_width = f64::from(logical.width()) / f64::from(SCALE);
        // Unusual fallback fonts may exceed Neovim's width policy. Fit the
        // whole line once; never insert padding or scale individual spans.
        let x_scale = cell_scale.min(f64::from(width) / natural_width.max(1.));
        let line_height = f64::from(logical.height()) / f64::from(SCALE);
        let y = top + (row_height - line_height) / 2. - f64::from(logical.y()) / f64::from(SCALE);
        cr.save()?;
        cr.rectangle(0., top, f64::from(width), row_height);
        cr.clip();
        let mut index = 0;
        for run in runs {
            let end = index + run.text.len() as i32;
            if let Some(bg) = run.bg {
                color(&cr, bg);
                if let Some(line) = layout.line_readonly(0) {
                    let ranges = line.x_ranges(index, end);
                    for &[left, right] in ranges.as_chunks::<2>().0 {
                        let left = f64::from(left) / f64::from(SCALE) * x_scale;
                        let right = f64::from(right) / f64::from(SCALE) * x_scale;
                        cr.rectangle(left, top, right - left, row_height);
                        cr.fill()?;
                    }
                }
            }
            index = end;
        }
        cr.translate(0., y);
        cr.scale(x_scale, 1.);
        cr.move_to(0., 0.);
        pangocairo::functions::show_layout(&cr, &layout);
        cr.restore()?;
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
        input.lines[0][0].cells = 257.;
        assert!(input.dimensions().is_err());
        input.lines[0][0].cells = 20.;
        input.cell_width = 256;
        input.cell_height = 256;
        input.lines = (0..64).map(|_| Vec::new()).collect();
        assert!(input.dimensions().is_err());
    }

    fn pixels(image: &ImageSurface) -> Vec<u8> {
        let mut result = Vec::new();
        image
            .with_data(|data| result.extend_from_slice(data))
            .unwrap();
        result
    }

    #[test]
    fn run_boundaries_do_not_insert_padding_inside_the_same_word() {
        for (text, parts, columns, ratio) in [
            (
                "inkstone.nvim",
                vec![("inkston", 14), ("e.nvim", 12)],
                26,
                2.0,
            ),
            ("必要なもの", vec![("必要なも", 12), ("の", 4)], 16, 1.5),
        ] {
            let mut whole = request();
            whole.font = "Liga Plemol Console NF".into();
            whole.columns = columns;
            whole.ratio = ratio;
            let template =
                serde_json::json!({"text":text,"cells":columns,"fg":0x839496,"bold":true});
            whole.lines = vec![vec![serde_json::from_value(template.clone()).unwrap()]];
            let expected = pixels(&raster(&whole).unwrap());
            whole.lines[0] = parts
                .into_iter()
                .map(|(text, cells)| {
                    let mut value = template.clone();
                    value["text"] = text.into();
                    value["cells"] = cells.into();
                    serde_json::from_value(value).unwrap()
                })
                .collect();
            assert!(
                pixels(&raster(&whole).unwrap()) == expected,
                "chunking changed {text}"
            );
        }
    }

    fn ink_bounds(image: &ImageSurface) -> (u32, u32) {
        let (mut left, mut top, mut right, mut bottom) = (u32::MAX, u32::MAX, 0, 0);
        image
            .with_data(|data| {
                for y in 0..image.height() as usize {
                    for x in 0..image.width() as usize {
                        let at = y * image.stride() as usize + x * 4;
                        let rgba = u32::from_ne_bytes(data[at..at + 4].try_into().unwrap());
                        if rgba >> 24 > 32 {
                            left = left.min(x as u32);
                            top = top.min(y as u32);
                            right = right.max(x as u32);
                            bottom = bottom.max(y as u32);
                        }
                    }
                }
            })
            .unwrap();
        assert_ne!(left, u32::MAX, "no visible glyph pixels");
        (right - left + 1, bottom - top + 1)
    }

    #[test]
    fn fractional_and_double_sizes_scale_ink_not_just_the_reserved_rows() {
        let mut input = request();
        input.font = "Liga Plemol Console NF".into();
        input.cell_width = 16;
        input.cell_height = 32;
        input.lines[0][0].text = "必要なもの".into();
        input.lines[0][0].bold = true;
        input.columns = 10;
        input.scale = 1;
        input.ratio = 1.;
        input.lines[0][0].cells = 10.;
        let base = ink_bounds(&raster(&input).unwrap());
        for ratio in [1.25_f64, 1.5, 2.] {
            input.ratio = ratio;
            input.scale = ratio.ceil() as u32;
            input.columns = (10. * ratio).ceil() as u32;
            input.lines[0][0].cells = 10. * ratio;
            let size = ink_bounds(&raster(&input).unwrap());
            assert!(
                (f64::from(size.0) - f64::from(base.0) * ratio).abs() <= 3.,
                "wrong ink width at {ratio}: {base:?} -> {size:?}"
            );
            assert!(
                (f64::from(size.1) - f64::from(base.1) * ratio).abs() <= 2.,
                "wrong ink height at {ratio}: {base:?} -> {size:?}"
            );
        }
    }
}
