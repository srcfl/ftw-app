#include <metal_stdlib>
using namespace metal;

// One continuous material, not a stack of colored discs. SwiftUI supplies
// the palette, site readings and the real contact point in display points.
[[ stitchable ]] half4 ftwSite(float2 position, half4 input, float2 size,
                              float4 power, float4 contact, float4 motion, float2 robot, float4 biases, float gridBias,
                              half4 home, half4 car, half4 battery, half4 solar,
                              half4 grid, half4 light) {
    float t = motion.y, grip = clamp(motion.x, -0.18f, 1.1f);
    float2 finger = contact.xy, origin = contact.zw;
    float2 delta = finger - origin;
    float2 p = position;

    // Backtrace the material under a grip. Nearby colors travel together.
    float2 local = p - finger;
    float influence = exp(-dot(local, local) / 23000.0f);
    p -= delta * influence * grip * 0.82f;
    float turn = clamp((delta.x - delta.y) / 180.0f, -0.9f, 0.9f) * influence * grip;
    float2 v = p - finger;
    p = finger + float2(v.x * cos(turn) - v.y * sin(turn), v.x * sin(turn) + v.y * cos(turn));

    float2 rest = size * float2(0.49f, 0.39f);
    float2 robotDelta = robot - rest;
    float2 nearRobot = p - robot;
    p -= robotDelta * exp(-dot(nearRobot, nearRobot) / (size.x * size.x * 0.32f)) * 0.45f;
    float2 uv = p / size;
    uv.x += sin(uv.y * 5.8f - t * 0.28f) * 0.065f;
    uv.y += sin(uv.x * 5.0f + t * 0.22f) * 0.035f;

    // Open adjoining color regions fill the screen. Their calibrated weights
    // follow power; there is no enclosing balloon or individual bubble rim.
    float4 score;
    score.x = -dot(uv - float2(0.23f, 0.175f), uv - float2(0.23f, 0.175f)) / 0.026f;
    score.y = -dot(uv - float2(0.79f, 0.30f), uv - float2(0.79f, 0.30f)) / 0.026f;
    score.z = -dot(uv - float2(0.22f, 0.53f), uv - float2(0.22f, 0.53f)) / 0.026f;
    score.w = -dot(uv - float2(0.76f, 0.665f), uv - float2(0.76f, 0.665f)) / 0.026f;
    score += biases;
    float scoreGrid = -dot(uv - float2(0.48f, 0.90f), uv - float2(0.48f, 0.90f)) / 0.026f + gridBias;
    float peak = max(max(max(score.x, score.y), max(score.z, score.w)), scoreGrid);
    float4 weights = exp(score - peak);
    float wg = exp(scoreGrid - peak);
    float sum = weights.x + weights.y + weights.z + weights.w + wg;
    half3 solarColor = power.x > 0.025f ? solar.rgb : mix(home.rgb, solar.rgb, 0.08h);
    half3 batteryColor = abs(power.z) > 0.025f ? battery.rgb : mix(home.rgb, battery.rgb, 0.32h);
    half3 gridColor = abs(motion.z) > 0.025f ? grid.rgb : mix(home.rgb, grid.rgb, 0.22h);
    half3 color = (solarColor * half(weights.x) + home.rgb * half(weights.y) + car.rgb * half(weights.z)
                   + batteryColor * half(weights.w) + gridColor * half(wg)) / half(sum);
    float warmth = clamp(sqrt(power.x / 6.0f), 0.0f, 1.2f);
    float sunWash = warmth * (0.025f + exp(-max(0.0f, uv.y) * 2.1f) * 0.12f);
    color = mix(color, solar.rgb, half(warmth * 0.045f));
    color = mix(color, light.rgb, half(sunWash));
    float alpha = smoothstep(0.0f, 0.065f, position.y / size.y);
    float netWidth = 14.0f + sqrt(abs(motion.z)) * 9.0f;
    float netX = size.x * 0.48f + sin(uv.y * 6.0f - 4.4f + t * 0.25f) * 10.0f;

    // A shared height field gives each open region a soft raised surface.
    // Analytic slopes produce light on one side and depth at the seam;
    // touching and dragging bend this height with the color itself.
    float4 area = weights / sum;
    float probabilities[5] = {area.x, area.y, area.z, area.w, wg / sum};
    float2 centers[5] = {float2(0.23f, 0.175f), float2(0.79f, 0.30f), float2(0.22f, 0.53f),
                          float2(0.76f, 0.665f), float2(0.48f, 0.90f)};
    float2 meanSlope = float2(0), squareSlope = float2(0);
    float height = 0;
    for (int i = 0; i < 5; ++i) {
        float a = probabilities[i];
        float2 slope = -2.0f * (uv - centers[i]) / 0.026f;
        meanSlope += a * slope;
        squareSlope += a * a * slope;
        height += a * a;
    }
    float2 surfaceSlope = 2.0f * (squareSlope - height * meanSlope);
    float3 normal = normalize(float3(-surfaceSlope * 0.075f, 1.0f));
    float3 lightDirection = normalize(float3(-0.45f, -0.60f, 0.70f));
    float diffuse = max(0.0f, dot(normal, lightDirection));
    float softShadow = 1.0f - 0.24f * (1.0f - height);
    color *= half((0.63f + diffuse * 0.51f) * softShadow);
    float highlight = pow(max(0.0f, dot(normal, normalize(lightDirection + float3(0, 0, 1)))), 36.0f);
    color = mix(color, light.rgb, half(highlight * 0.22f));

    // Long, quiet folds pass through the common material. Their edges never
    // outline a separate part. The grid opening carries only its signed flow.
    float ridge = exp(-pow((uv.x - 0.44f - sin(uv.y * 5.8f - t * 0.24f) * 0.19f) / 0.10f, 2.0f));
    float gleam = ridge * (0.06f + pow(0.5f + 0.5f * sin(uv.y * 8.0f - t * 1.25f), 4.0f) * 0.12f);
    color = mix(color, light.rgb, half(gleam));
    float network = smoothstep(0.72f, 0.96f, uv.y) * exp(-pow((p.x - netX) / netWidth, 2.0f));
    color = mix(color, grid.rgb, half(network * 0.72f));
    if (abs(motion.z) > 0.025f) {
        float direction = motion.z > 0.0f ? 1.0f : -1.0f;
        float front = pow(0.5f + 0.5f * sin(uv.y * 16.0f + t * direction * (1.5f + sqrt(abs(motion.z)))), 5.0f);
        color = mix(color, light.rgb, half(network * front * 0.26f));
    }
    return half4(color * half(alpha), half(alpha)) * input.a;
}

// An open fold continues beyond the screen, with the site's soft seam and
// directional light. The top is colored material; the lower surface opens
// into the page. There is no closed oval around the header.
[[ stitchable ]] half4 ftwFold(float2 position, half4 input, float2 size, float4 state,
                              float2 contact, half4 primary, half4 companion,
                              half4 ground, half4 light) {
    float2 uv = position / max(size, float2(1));
    float phase = state.x, time = state.y;
    float reach = 0.78f + sin(phase * 0.9f) * 0.035f;
    float2 drag = contact / max(size, float2(1));
    float influence = exp(-dot(uv - float2(0.72f, 0.45f), uv - float2(0.72f, 0.45f)) * 4.0f);
    uv -= drag * influence * 0.70f;
    float wave = uv.x * 3.8f + phase * 0.45f;
    float seam = reach + cos(wave) * 0.14f;
    float d = (seam - uv.y) / 0.075f;
    float a = 1.0f / (1.0f + exp(-d));
    float dx = -sin(wave) * 0.14f * 3.8f / 0.075f;
    float dy = -1.0f / 0.075f;
    float height = a * a + (1.0f - a) * (1.0f - a);
    float2 slope = (4.0f * a - 2.0f) * a * (1.0f - a) * float2(dx, dy);
    float3 normal = normalize(float3(-slope * 0.14f, 1));
    float3 direction = normalize(float3(-0.45f, -0.60f, 0.70f));
    float diffuse = max(0.0f, dot(normal, direction));
    float shade = (0.63f + diffuse * 0.51f) * (1.0f - 0.24f * (1.0f - height));
    half3 color = mix(companion.rgb, primary.rgb, half(a));
    color *= half(shade);
    float specular = pow(max(0.0f, dot(normal, normalize(direction + float3(0, 0, 1)))), 36.0f);
    color = mix(color, light.rgb, half(specular * 0.22f));
    if (state.z > 0.025f) {
        float lightPath = exp(-pow((uv.x - 0.52f - sin(uv.y * 4.0f + phase) * 0.2f) / 0.12f, 2.0f));
        float front = pow(0.5f + 0.5f * sin(uv.y * 7.0f - time * (0.8f + sqrt(state.z) * 0.4f)), 4.0f);
        color = mix(color, light.rgb, half(lightPath * front * a * 0.18f));
    }
    float fade = smoothstep(0.0f, 0.065f, position.y / max(1.0f, size.y))
               * (1.0f - smoothstep(0.76f, 1.0f, position.y / max(1.0f, size.y)));
    color = mix(ground.rgb, color, half(clamp(state.w, 0.0f, 1.0f) * fade));
    return half4(color, 1) * input.a;
}

// Past energy holds still. One complete sine across the width keeps the
// area at the given share while a horizontal grip reshapes its boundary.
[[ stitchable ]] half4 ftwHistory(float2 position, half4 input, float2 size,
                                 float share, float phase, half4 top, half4 bottom, half4 light) {
    float2 uv = position / max(size, float2(1));
    float amplitude = min(share, 1.0f - share) * 0.38f;
    float wave = uv.x * 6.2831853f + phase;
    float seam = share + sin(wave) * amplitude;
    float d = (seam - uv.y) / 0.018f;
    float a = 1.0f / (1.0f + exp(-d));
    float2 gradient = float2(cos(wave) * amplitude * 6.2831853f, -1) / 0.018f;
    float2 slope = (4.0f * a - 2.0f) * a * (1.0f - a) * gradient;
    float3 normal = normalize(float3(-slope * 0.035f, 1));
    float3 direction = normalize(float3(-0.45f, -0.60f, 0.70f));
    float height = a * a + (1.0f - a) * (1.0f - a);
    half3 color = mix(bottom.rgb, top.rgb, half(a));
    color *= half((0.63f + max(0.0f, dot(normal, direction)) * 0.51f) * (1.0f - 0.24f * (1.0f - height)));
    float specular = pow(max(0.0f, dot(normal, normalize(direction + float3(0, 0, 1)))), 36.0f);
    return half4(mix(color, light.rgb, half(specular * 0.22f)), 1) * input.a;
}

static float ftwRoundRect(float2 p, float2 center, float2 halfSize, float radius) {
    float2 d = abs(p - center) - max(halfSize - radius, float2(0));
    return length(max(d, float2(0))) + min(max(d.x, d.y), 0.0f) - radius;
}

static float ftwPlanDistance(float2 p, float2 size, float4 powers) {
    float zero = size.y * 4.0f / 7.0f;
    float distance = ftwRoundRect(p, float2(size.x * 0.5f, zero), float2(size.x * 0.49f, 3.5f), 3.5f);
    for (int i = 0; i < 4; ++i) {
        float power = powers[i];
        if (abs(power) < 0.025f) continue;
        float height = abs(power) * size.y / 7.0f;
        float2 center = float2(size.x * (float(i) + 0.5f) / 4.0f, zero - power * size.y / 14.0f);
        float2 halfSize = float2(size.x * 0.125f, height * 0.5f);
        float radius = min(halfSize.x, halfSize.y);
        float column = ftwRoundRect(p, center, halfSize, radius);
        // Rounded shared joins at zero; no sharp triangles or thin curls.
        float h = clamp(0.5f + 0.5f * (column - distance) / 12.0f, 0.0f, 1.0f);
        distance = mix(column, distance, h) - 12.0f * h * (1.0f - h);
    }
    return distance;
}

[[ stitchable ]] half4 ftwPlan(float2 position, half4 input, float2 size, float4 powers,
                              float4 touch, half4 material, half4 ground, half4 light) {
    float distance = ftwPlanDistance(position, size, powers);
    // Shade a smooth height field rather than the distance field's medial
    // axes. This avoids faceted highlights in the middle of a rounded lobe.
    float zero = size.y * 4.0f / 7.0f;
    float2 slope = float2(0);
    for (int i = 0; i < 4; ++i) {
        float power = powers[i];
        if (abs(power) < 0.025f) continue;
        float height = abs(power) * size.y / 7.0f;
        float2 center = float2(size.x * (float(i) + 0.5f) / 4.0f, zero - power * size.y / 14.0f);
        float2 radius = max(float2(14), float2(size.x * 0.125f, height * 0.5f));
        float2 local = (position - center) / radius;
        float dome = exp(-dot(local, local) * 0.8f);
        slope += -local / radius * dome * 24.0f;
    }
    float2 local = position - touch.xy * size;
    float contact = exp(-dot(local, local) / 2200.0f) * touch.z;
    slope += local * contact * 0.008f;
    float3 normal = normalize(float3(-slope, 1));
    float3 direction = normalize(float3(-0.45f, -0.60f, 0.70f));
    half3 color = material.rgb * half(0.65f + max(0.0f, dot(normal, direction)) * 0.45f);
    float specular = pow(max(0.0f, dot(normal, normalize(direction + float3(0, 0, 1)))), 24.0f);
    color = mix(color, light.rgb, half(specular * 0.22f + contact * 0.10f));
    float alpha = 1.0f - smoothstep(-0.8f, 0.8f, distance);
    float shadow = exp(-max(0.0f, distance) * max(0.0f, distance) / 34.0f) * 0.10f;
    float shadowAlpha = shadow * (1.0f - alpha);
    float outAlpha = alpha + shadowAlpha;
    return half4(color * half(alpha) + ground.rgb * half(shadowAlpha), half(outAlpha)) * input.a;
}
