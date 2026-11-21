package com.hiennv.flutter_callkit_incoming.widgets

import android.graphics.*
import coil.bitmap.BitmapPool
import coil.size.Size
import coil.transform.Transformation
import kotlin.math.min


class CircleTransform : Transformation {

    override fun key(): String {
        return "circle"
    }

    override suspend fun transform(pool: BitmapPool, input: Bitmap, size: Size): Bitmap {
        val sizeImage = min(input.width, input.height)
        val x = (input.width - sizeImage) / 2
        val y = (input.height - sizeImage) / 2
        val squaredBitmap = Bitmap.createBitmap(input, x, y, sizeImage, sizeImage)
        if (squaredBitmap != input) {
            input.recycle()
        }
        val config = input.config ?: Bitmap.Config.ARGB_8888
        val bitmap = Bitmap.createBitmap(sizeImage, sizeImage, config)
        val canvas = Canvas(bitmap)
        val paint = Paint()
        val shader = BitmapShader(
            squaredBitmap,
            Shader.TileMode.CLAMP, Shader.TileMode.CLAMP
        )
        paint.shader = shader
        paint.isAntiAlias = true
        val r = sizeImage / 2f
        canvas.drawCircle(r, r, r, paint)
        squaredBitmap.recycle()
        return bitmap
    }
}