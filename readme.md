<p align="center">
  <img src="logo.png" alt="Zoom to Mouse Logo" width="160" height="160">
</p>

<h1 align="center">OBS Zoom to Mouse</h1>

<p align="center">
  <b>A powerful, ultra-smooth OBS Lua script that dynamically zooms your display capture and precisely follows your mouse cursor.</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/OBS-Studio-7C3AED?style=for-the-badge&logo=obsstudio&logoColor=white" alt="OBS Studio">
  <img src="https://img.shields.io/badge/Platform-Windows%20%7C%20Linux%20%7C%20macOS-blue?style=for-the-badge" alt="Platforms">
  <img src="https://img.shields.io/badge/Lua-Script-000080?style=for-the-badge&logo=lua&logoColor=white" alt="Lua">
  <img src="https://img.shields.io/badge/License-MIT-green?style=for-the-badge" alt="License">
</p>

---

> **✨ Modernized & Updated:** This is an enhanced fork optimized and updated for the latest **OBS Studio** versions by **Timww**, originally built by **BlankSourceCode**.

---

## 📽️ Preview

![Usage Demo](obs-zoom-to-mouse.gif)

---

## ⚡ Key Features

| Feature | Description |
| :--- | :--- |
| **🚀 Ultra-Smooth Zoom** | Fluid, animated zoom transitions directly focused on your current mouse position. |
| **🎯 Smart Mouse Tracking** | Automatically tracks your cursor with configurable deadzones, follow speeds, and boundary locks. |
| **🛠️ Highly Configurable** | Full control over zoom factors, animation speeds, tracking borders, and custom source bounds. |
| **🌐 Multi-Platform** | Fully compatible across **Windows**, **Linux**, and **macOS**. |
| **🖥️ Dual Machine Support** | Integrates with remote clients via UDP sockets for secondary machine setup. |

---

## 📦 Installation

1. Download or clone this repository (make sure you have `ZoomToMouse.Vx.x.x.lua`).
2. Launch **OBS Studio**.
3. Add a **Display Capture** source to your scene (recommended for automatic positioning).
4. Go to **Tools** -> **Scripts** in OBS.
5. Click the **`+`** button and select `obs-zoom-to-mouse.lua`.

---

## ⚙️ Recommended Source Setup

For best results, configure your **Display Capture** source with these settings:
* **Transform:**
  * Positional Alignment: `Top Left`
  * Bounding Box Type: `Scale to inner bounds`
  * Alignment in Bounding Box: `Top Left`
  * Crop: All **zeros**

> ⚠️ *Note:* If you use custom bounds or crops, the script will attempt to auto-correct them. If you change your display layout in Windows/Linux/Mac, re-add the display capture source and reload the script.

---

## 🎛️ Configuration Options

You can fine-tune every parameter directly from the OBS Scripts window:

* **Zoom Source:** Choose which source to target.
* **Zoom Factor & Speed:** Adjust magnification power and transition smoothness.
* **Auto Follow Mouse:** Track cursor movement automatically when zoomed in.
* **Follow Border & Lock Sensitivity:** Define deadzones and safe areas where the camera stands still.
* **Show All Sources:** Enable targeting for window captures, browser sources, or cloned scenes (requires manual coordinate input).

---

## 📜 Credits & Acknowledgments

* **Original Creator:** [BlankSourceCode](https://github.com/BlankSourceCode) ([obs-zoom-to-mouse](https://github.com/BlankSourceCode/obs-zoom-to-mouse))
* **Inspiration:** [tryptech](https://github.com/tryptech)'s [obs-zoom-and-follow](https://github.com/tryptech/obs-zoom-and-follow)
* **Updated & Maintained for Modern OBS:** **Timexo**

---

<p align="center">
  <a href="https://timexo.gumroad.com/coffee" target="_blank">
    <img src="https://cdn.buymeacoffee.com/buttons/default-orange.png" alt="Buy Me A Coffee" height="41" width="174">
  </a>
</p>
