import fs from "fs";
import path from "path";
import os from "os";
import { execSync } from "child_process";

const projectRoot = process.cwd();
const localNext = path.join(projectRoot, ".next");
const webpackCache = path.join(os.tmpdir(), "smartqueue-webpack-cache");
const tempNext = path.join(os.tmpdir(), "smartqueue-next");
const nodeCache = path.join(projectRoot, "node_modules", ".cache");

function rmNextDir() {
  if (!fs.existsSync(localNext)) return;
  try {
    const stat = fs.lstatSync(localNext);
    if (stat.isSymbolicLink()) {
      fs.unlinkSync(localNext);
      console.log("[clean-next] junction .next removida");
      return;
    }
  } catch {
    /* ignore */
  }
  try {
    fs.rmSync(localNext, { recursive: true, force: true });
    console.log(`[clean-next] removido: ${localNext}`);
  } catch (err) {
    console.warn(`[clean-next] falha .next — tenta fechar o dev server:`, err.message);
    if (process.platform === "win32") {
      try {
        execSync(`cmd /c rmdir /s /q "${localNext}"`, { stdio: "ignore" });
        console.log("[clean-next] removido via rmdir /s /q");
      } catch {
        /* ignore */
      }
    }
  }
}

rmNextDir();

for (const dir of [webpackCache, tempNext, nodeCache]) {
  try {
    fs.rmSync(dir, { recursive: true, force: true });
    console.log(`[clean-next] removido: ${dir}`);
  } catch (err) {
    console.warn(`[clean-next] skip ${dir}:`, err.message);
  }
}
