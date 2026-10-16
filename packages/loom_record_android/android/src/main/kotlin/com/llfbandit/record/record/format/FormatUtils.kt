package com.llfbandit.record.record.format

import android.util.Log
import kotlin.math.abs

internal fun nearestValue(values: IntArray, value: Int): Int {
  var distance = abs(values[0] - value)
  var idx = 0

  for (c in 1 until values.size) {
    val cDistance = abs(values[c] - value)
    if (cDistance < distance) {
      idx = c
      distance = cDistance
    }
  }

  if (value != values[idx]) {
    Log.d("nearestValue", "Available values: ${values.indices.map { values[it] }}")
    Log.d("nearestValue", "Adjusted to: ${values[idx]}")
  }

  return values[idx]
}
