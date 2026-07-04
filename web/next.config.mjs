import path from "path";
import os from "os";

/** @type {import('next').NextConfig} */
const nextConfig = {
  allowedDevOrigins: ["127.0.0.1", "localhost"],
  webpack: (config, { dev }) => {
    if (dev) {
      config.cache = {
        type: "filesystem",
        cacheDirectory: path.join(os.tmpdir(), "smartqueue-webpack-cache"),
      };
    }
    return config;
  },
};

export default nextConfig;
