fn main() {
    if let Err(error) = flyology_db_slatedb_benchmark::run_cli() {
        eprintln!("flyology-db-slatedb-benchmark: {error}");
        std::process::exit(2);
    }
}
