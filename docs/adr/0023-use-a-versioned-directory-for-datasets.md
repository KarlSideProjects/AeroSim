# Use a versioned directory for datasets

Dataset Recording will write one portable, versioned directory containing `manifest.json`, `samples.jsonl`, PNG RGB and segmentation images, PFM planar-depth images, and little-endian float32 LiDAR points. The first release will not require a database, Parquet, or ROS bag; interrupted recordings remain marked incomplete and become valid only after atomic finalization and validation, preventing partial data from being mistaken for a complete dataset.
