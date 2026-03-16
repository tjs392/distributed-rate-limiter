/*
    build.rs:
    Builds the wire protocols needed for the Envoy interface
    with GRPC
*/
fn main() {
    tonic_prost_build::configure()
        .compile_protos(&["proto/rls.proto"], &["proto"])
        .unwrap();
}