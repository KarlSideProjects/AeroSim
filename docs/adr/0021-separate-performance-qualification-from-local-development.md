# Separate performance qualification from local development

Player Mode will target stable 60 FPS at 1080p default quality, and the documented two-vehicle Lab Mode workload will target real-time factor at least 1.0, on the designated Ubuntu 26.04 LTS runner with AMD Ryzen 9 7945HX, NVIDIA GeForce RTX 4060 Ti, and NVIDIA driver 580.159.03. Only that runner blocks on performance; lower-spec local machines still run functional and deterministic checks with reduced quality or sensor rates and report performance as not qualified rather than failed.
