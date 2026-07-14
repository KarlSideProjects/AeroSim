# Separate performance qualification from local development

Player Mode will target stable 60 FPS at 1080p default quality, and the documented two-vehicle Lab Mode workload will target real-time factor at least 1.0, on a designated Ubuntu runner with a 6-core CPU, 16 GB RAM, and RTX 3060 12 GB-class GPU. Only that runner blocks on performance; lower-spec local machines still run functional and deterministic checks with reduced quality or sensor rates and report performance as not qualified rather than failed.
