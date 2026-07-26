//! Elysium exchange writer.
//!
//! This is an Elysium-maintained adapter around Arnis' in-memory world. It is deliberately
//! independent of Elysium's SQLite schema: the native app validates the complete directory
//! before committing any world record or chunk. `manifest.json` is renamed into place last,
//! so an interrupted generator is never mistaken for complete output.

use super::common::WorldToModify;
use crate::block_definitions::{AIR, WATER};
use crate::coordinate_system::cartesian::XZBBox;
use crate::coordinate_system::geographic::LLBBox;
use serde::Serialize;
use std::collections::BTreeMap;
use std::fs::{self, File};
use std::io::{BufWriter, Write};
use std::path::Path;

const STREAM_MAGIC: &[u8; 8] = b"ELEXSTR3";
const MIN_SECTION: i8 = -4;
const MAX_SECTION: i8 = 19;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ExchangeBlock {
    id: u16,
    name: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ExchangeManifest {
    format: &'static str,
    version: u32,
    complete: bool,
    generator: &'static str,
    chunk_count: usize,
    min_chunk_x: i32,
    max_chunk_x: i32,
    min_chunk_z: i32,
    max_chunk_z: i32,
    min_geo_lat: f64,
    max_geo_lat: f64,
    min_geo_lon: f64,
    max_geo_lon: f64,
    projection: String,
    scale: f64,
    spawn_x: i32,
    spawn_y: i32,
    spawn_z: i32,
    stream_bytes: u64,
    blocks: Vec<ExchangeBlock>,
}

fn write_u16(writer: &mut impl Write, value: u16) -> std::io::Result<()> {
    writer.write_all(&value.to_le_bytes())
}

fn write_u32(writer: &mut impl Write, value: u32) -> std::io::Result<()> {
    writer.write_all(&value.to_le_bytes())
}

fn write_i32(writer: &mut impl Write, value: i32) -> std::io::Result<()> {
    writer.write_all(&value.to_le_bytes())
}

fn write_i16(writer: &mut impl Write, value: i16) -> std::io::Result<()> {
    writer.write_all(&value.to_le_bytes())
}

pub(super) fn save_elysium_exchange(
    world: &WorldToModify,
    output: &Path,
    xzbbox: &XZBBox,
    llbbox: &LLBBox,
    projection: &str,
    scale: f64,
    spawn: Option<(i32, i32)>,
    ground_level: impl Fn(i32, i32) -> i32,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if output.exists() {
        return Err(format!(
            "Elysium exchange destination already exists: {}",
            output.display()
        )
        .into());
    }
    fs::create_dir_all(output)?;

    let mut chunk_entries = Vec::new();
    for (&(rx, rz), region) in &world.regions {
        for (&(local_x, local_z), chunk) in &region.chunks {
            chunk_entries.push((rx * 32 + local_x, rz * 32 + local_z, chunk));
        }
    }
    chunk_entries.sort_by_key(|(cx, cz, _)| (*cx, *cz));

    let stream_partial = output.join("chunks.elxstream.partial");
    let mut stream = BufWriter::new(File::create_new(&stream_partial)?);
    stream.write_all(STREAM_MAGIC)?;
    write_u32(&mut stream, u32::try_from(chunk_entries.len())?)?;

    let mut used_blocks: BTreeMap<u16, String> = BTreeMap::new();
    for (cx, cz, chunk) in &chunk_entries {
        let mut payload = Vec::with_capacity(32 * 1024);
        write_i32(&mut payload, *cx)?;
        write_i32(&mut payload, *cz)?;

        let mut sections: Vec<_> = chunk
            .sections
            .iter()
            .filter(|(section_y, _)| **section_y >= MIN_SECTION && **section_y <= MAX_SECTION)
            .collect();
        sections.sort_by_key(|(section_y, _)| **section_y);
        write_u16(&mut payload, u16::try_from(sections.len())?)?;

        for (&section_y, section) in sections {
            payload.write_all(&section_y.to_le_bytes())?;
            let mut runs: Vec<(u16, u16)> = Vec::new();
            let mut current = section.exchange_block_at(0).id();
            let mut length: u16 = 1;
            for index in 1..4096 {
                let id = section.exchange_block_at(index).id();
                if id == current && length < u16::MAX {
                    length += 1;
                } else {
                    runs.push((length, current));
                    current = id;
                    length = 1;
                }
            }
            runs.push((length, current));
            write_u16(&mut payload, u16::try_from(runs.len())?)?;
            for (run_length, id) in runs {
                write_u16(&mut payload, run_length)?;
                write_u16(&mut payload, id)?;
                let block = crate::block_definitions::Block::from_raw_id_for_exchange(id);
                used_blocks
                    .entry(id)
                    .or_insert_with(|| block.name().to_string());
            }

            let properties: Vec<_> = (0..4096)
                .filter_map(|index| {
                    section
                        .exchange_properties_at(index)
                        .map(|value| (index, value))
                })
                .collect();
            write_u16(&mut payload, u16::try_from(properties.len())?)?;
            for (index, value) in properties {
                let json = serde_json::to_vec(value)?;
                write_u16(&mut payload, u16::try_from(index)?)?;
                write_u32(&mut payload, u32::try_from(json.len())?)?;
                payload.write_all(&json)?;
            }
        }

        // The native importer needs the unbuilt terrain surface, not the highest placed
        // block: using roofs would make the transition collar distort around buildings.
        for local_z in 0..16 {
            for local_x in 0..16 {
                let world_x = *cx * 16 + local_x;
                let world_z = *cz * 16 + local_z;
                write_i16(&mut payload, i16::try_from(ground_level(world_x, world_z))?)?;
            }
        }
        write_u32(&mut stream, u32::try_from(payload.len())?)?;
        stream.write_all(&payload)?;
    }
    stream.flush()?;
    drop(stream);
    fs::rename(&stream_partial, output.join("chunks.elxstream"))?;
    let stream_bytes = fs::metadata(output.join("chunks.elxstream"))?.len();

    let default_spawn = (
        (xzbbox.min_x() + xzbbox.max_x()) / 2,
        (xzbbox.min_z() + xzbbox.max_z()) / 2,
    );
    let (spawn_x, spawn_z) = spawn.unwrap_or(default_spawn);
    let spawn_y = (MIN_SECTION as i32 * 16..=MAX_SECTION as i32 * 16 + 15)
        .rev()
        .find(|y| {
            world
                .get_block(spawn_x, *y, spawn_z)
                .is_some_and(|block| block != AIR && block != WATER)
        })
        .map(|y| y + 1)
        .unwrap_or_else(|| ground_level(spawn_x, spawn_z) + 1)
        .clamp(MIN_SECTION as i32 * 16 + 1, MAX_SECTION as i32 * 16 + 14);
    let min_chunk_x = chunk_entries.first().map(|entry| entry.0).unwrap_or(0);
    let max_chunk_x = chunk_entries.last().map(|entry| entry.0).unwrap_or(0);
    let min_chunk_z = chunk_entries.iter().map(|entry| entry.1).min().unwrap_or(0);
    let max_chunk_z = chunk_entries.iter().map(|entry| entry.1).max().unwrap_or(0);
    let manifest = ExchangeManifest {
        format: "elysium-reality-exchange",
        version: 3,
        complete: true,
        generator: "Arnis 3.0.0 + Elysium adapter",
        chunk_count: chunk_entries.len(),
        min_chunk_x,
        max_chunk_x,
        min_chunk_z,
        max_chunk_z,
        min_geo_lat: llbbox.min().lat(),
        max_geo_lat: llbbox.max().lat(),
        min_geo_lon: llbbox.min().lng(),
        max_geo_lon: llbbox.max().lng(),
        projection: projection.to_string(),
        scale,
        spawn_x,
        spawn_y,
        spawn_z,
        stream_bytes,
        blocks: used_blocks
            .into_iter()
            .map(|(id, name)| ExchangeBlock { id, name })
            .collect(),
    };
    let partial = output.join("manifest.json.partial");
    serde_json::to_writer(BufWriter::new(File::create_new(&partial)?), &manifest)?;
    fs::rename(partial, output.join("manifest.json"))?;
    Ok(())
}
