# StableDiffusionKit

Apple's Stable Diffusion implementation for MLX Swift, copied from
`ml-explore/mlx-swift-examples/Libraries/StableDiffusion` at main (378f244)
under its MIT licence. It is a local package rather than a dependency because
the upstream manifest declares iOS 16 while MLX requires iOS 17. The only source
changes are four unused-variable warnings silenced so the app's Release build
is warning-free; the manifest is new.
