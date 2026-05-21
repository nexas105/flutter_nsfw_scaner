package com.example.nsfw_detect_ios.util

import android.content.Context
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.util.Log

/**
 * Observes battery + thermal state and produces a workload multiplier the
 * scan / camera pipelines apply to concurrency, FPS and similar knobs.
 *
 * Pendant to iOS' `ProcessInfo.thermalState` + `Process.isLowPowerModeEnabled`
 * checks — Android exposes the same two signals via
 * [PowerManager.isPowerSaveMode], [BatteryManager.BATTERY_PROPERTY_CAPACITY]
 * and (API 29+) [PowerManager.OnThermalStatusChangedListener].
 *
 * Workload multiplier semantics:
 *  - `1.0` → run at full speed (NOMINAL, charged, no power save).
 *  - `0.75` → throttle by 25% (MODERATE thermal).
 *  - `0.5` → halve the workload (SEVERE / CRITICAL thermal, or power save +
 *    `<20%` battery).
 *
 * Lifecycle: callers create one [DeviceLoadMonitor] per session, call
 * [start] to register the thermal listener (no-op below API 29), and
 * [stop] when the session ends. [currentMultiplier] / [snapshot] are safe
 * to call at any time.
 */
class DeviceLoadMonitor(private val context: Context) {

    private val appContext: Context = context.applicationContext

    @Volatile
    private var thermalMultiplier: Double = 1.0

    private var thermalListener: PowerManager.OnThermalStatusChangedListener? = null

    /**
     * Snapshot of the current device-load state. Useful for one-shot reads
     * (e.g. choosing initial scan concurrency before the listener has
     * fired anything).
     */
    data class Snapshot(
        val isPowerSaveMode: Boolean,
        val isLowBattery: Boolean,
        val thermalMultiplier: Double,
        val combinedMultiplier: Double,
    )

    /**
     * Start observing thermal status changes. Below API 29 this is a no-op;
     * the battery / power-save signals remain available via [snapshot].
     * Safe to call multiple times — subsequent calls are no-ops.
     */
    fun start() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        if (thermalListener != null) return
        val pm = appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
        val listener = PowerManager.OnThermalStatusChangedListener { status ->
            thermalMultiplier = multiplierForThermalStatus(status)
            Log.i(TAG, "Thermal status changed: $status -> multiplier=$thermalMultiplier")
        }
        try {
            pm.addThermalStatusListener(listener)
            // Seed with the current status so callers don't see 1.0 until the
            // first transition.
            thermalMultiplier = multiplierForThermalStatus(pm.currentThermalStatus)
            thermalListener = listener
        } catch (t: Throwable) {
            Log.w(TAG, "addThermalStatusListener failed: ${t.message}")
        }
    }

    /** Unregister the thermal listener. Safe to call multiple times. */
    fun stop() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val listener = thermalListener ?: return
        val pm = appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager
        try {
            pm?.removeThermalStatusListener(listener)
        } catch (_: Throwable) {}
        thermalListener = null
    }

    /** True when system-wide Power Save mode is enabled. */
    fun isPowerSaveMode(): Boolean {
        val pm = appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager
            ?: return false
        return try { pm.isPowerSaveMode } catch (_: Throwable) { false }
    }

    /** True when battery capacity is below 20% (and we could read it). */
    fun isLowBattery(): Boolean {
        val bm = appContext.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
            ?: return false
        return try {
            val pct = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
            pct in 1..19  // 0 = read failed on some devices; treat as unknown.
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * Combined multiplier reflecting both battery and thermal state. The
     * lower of the two signals wins, so a "moderate-thermal + power-save"
     * device gets the more conservative 0.5 (not 0.75).
     */
    fun currentMultiplier(): Double {
        val batteryMul = if (isPowerSaveMode() || isLowBattery()) 0.5 else 1.0
        return minOf(batteryMul, thermalMultiplier)
    }

    /** One-shot snapshot of everything the monitor knows about right now. */
    fun snapshot(): Snapshot {
        val ps = isPowerSaveMode()
        val lb = isLowBattery()
        val tm = thermalMultiplier
        val battMul = if (ps || lb) 0.5 else 1.0
        return Snapshot(
            isPowerSaveMode = ps,
            isLowBattery = lb,
            thermalMultiplier = tm,
            combinedMultiplier = minOf(battMul, tm),
        )
    }

    /**
     * Apply [currentMultiplier] to an integer knob (e.g. concurrency, FPS),
     * coercing the result into `[min, original]`. Helper saves call sites
     * from repeating the rounding + floor dance.
     */
    fun applyToInt(original: Int, min: Int = 1): Int {
        val scaled = (original * currentMultiplier()).toInt()
        return scaled.coerceAtLeast(min).coerceAtMost(original)
    }

    private fun multiplierForThermalStatus(status: Int): Double {
        // PowerManager.THERMAL_STATUS_* constants exist on API 29+; we still
        // index by Int so the function compiles for callers on older SDKs.
        return when (status) {
            // NONE, LIGHT — treat as nominal.
            0, 1 -> 1.0
            // MODERATE — back off 25%.
            2 -> 0.75
            // SEVERE, CRITICAL, EMERGENCY, SHUTDOWN — halve.
            3, 4, 5, 6 -> 0.5
            else -> 1.0
        }
    }

    private companion object {
        const val TAG = "NSFW-DeviceLoad"
    }
}
