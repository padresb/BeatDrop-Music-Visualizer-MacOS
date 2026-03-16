#include "Loudness.hpp"

#include <cmath>

namespace libprojectM {
namespace Audio {

// Logarithmic (octave-based) band ranges matching the original MilkDrop.
// The spectrum covers 0 Hz to ~22050 Hz across SpectrumSamples (512) bins.
// Original MilkDrop divides 20–20000 Hz into 3 bands of equal octave width:
//   net_octaves = log2(20000/20) = ~9.97
//   octaves_per_band = 9.97 / 3 = ~3.32
//   mult = 2^3.32 = ~10.0
// Band boundaries: 20, 200, 2000, 20000 Hz
// Bin index = SpectrumSamples * freq / max_freq  (max_freq = 22050 Hz)
//   Bass:   bins 0..4    (0–215 Hz)
//   Mids:   bins 5..46   (215–2024 Hz)
//   Treble: bins 47..464 (2024–20000 Hz)
static constexpr float kMinFreq = 20.0f;
static constexpr float kMaxFreq = 20000.0f;
static constexpr float kNyquist = 22050.0f;

static void LogBandRange(int bandIndex, int spectrumSize, int& outStart, int& outEnd)
{
    float netOctaves = std::log2(kMaxFreq / kMinFreq);
    float octavesPerBand = netOctaves / 3.0f;
    float mult = std::pow(2.0f, octavesPerBand);

    float startFreq = kMinFreq * std::pow(mult, static_cast<float>(bandIndex));
    float endFreq = kMinFreq * std::pow(mult, static_cast<float>(bandIndex + 1));

    outStart = static_cast<int>(static_cast<float>(spectrumSize) * startFreq / kNyquist);
    outEnd = static_cast<int>(static_cast<float>(spectrumSize) * endFreq / kNyquist);

    if (outStart < 0)
    {
        outStart = 0;
    }
    if (outEnd > spectrumSize)
    {
        outEnd = spectrumSize;
    }
}

Loudness::Loudness(Loudness::Band band)
    : m_band(band)
{
}

void Loudness::Update(const std::array<float, SpectrumSamples>& spectrumSamples, double secondsSinceLastFrame, uint32_t frame)
{
    SumBand(spectrumSamples);
    UpdateBandAverage(secondsSinceLastFrame, frame);
}

auto Loudness::CurrentRelative() const -> float
{
    return m_currentRelative;
}

auto Loudness::AverageRelative() const -> float
{
    return m_averageRelative;
}

void Loudness::SumBand(const std::array<float, SpectrumSamples>& spectrumSamples)
{
    int start = 0;
    int end = 0;
    LogBandRange(static_cast<int>(m_band), SpectrumSamples, start, end);

    m_current = 0.0f;
    for (int sample = start; sample < end; sample++)
    {
        m_current += spectrumSamples[sample];
    }

    // Normalize by the number of bins so that narrow bands (bass) and wide
    // bands (treble) produce comparable magnitudes, matching the original
    // MilkDrop which divides by (end - start).
    int count = end - start;
    if (count > 0)
    {
        m_current /= static_cast<float>(count);
    }

    // Apply empirical calibration factors from the original MilkDrop.
    // These were determined from 244 songs (10 seconds each) to equalize
    // the three bands so they produce similar magnitude values for typical
    // music. Without these, bass dominates and treble is proportionally weak.
    // See: vis_milk2/pluginshell.cpp lines 1848-1855.
    static constexpr float kCalibration[] = {
        0.326781557f, // Bass average level
        0.380873770f, // Mids average level
        0.199888934f  // Treble average level
    };
    m_current /= kCalibration[static_cast<int>(m_band)];
}

void Loudness::UpdateBandAverage(double secondsSinceLastFrame, uint32_t frame)
{
    float rate = AdjustRateToFps(m_current > m_average ? 0.2f : 0.5f, secondsSinceLastFrame);
    m_average = m_average * rate + m_current * (1.0f - rate);

    rate = AdjustRateToFps(frame < 50 ? 0.9f : 0.992f, secondsSinceLastFrame);
    m_longAverage = m_longAverage * rate + m_current * (1.0f - rate);

    m_currentRelative = std::fabs(m_longAverage) < 0.001f ? 1.0f : m_current / m_longAverage;
    m_averageRelative = std::fabs(m_longAverage) < 0.001f ? 1.0f : m_average / m_longAverage;
}

auto Loudness::AdjustRateToFps(float rate, double secondsSinceLastFrame) -> float
{
    float const perSecondDecayRateAtFps1 = std::pow(rate, 30.0f);
    float const perFrameDecayRateAtFps2 = std::pow(perSecondDecayRateAtFps1, static_cast<float>(secondsSinceLastFrame));

    return perFrameDecayRateAtFps2;
}

} // namespace Audio
} // namespace libprojectM
