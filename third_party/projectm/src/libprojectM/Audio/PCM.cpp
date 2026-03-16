#include "PCM.hpp"

#include <algorithm>
#include <cmath>

namespace libprojectM {
namespace Audio {

template<
    int signalAmplitude,
    int signalOffset,
    typename SampleType>
void PCM::AddToBuffer(
    SampleType const* const samples,
    uint32_t channels,
    size_t const sampleCount)
{
    if (channels == 0 || sampleCount == 0)
    {
        return;
    }

    for (size_t i = 0; i < sampleCount; i++)
    {
        size_t const bufferOffset = (m_start + i) % AudioBufferSamples;
        m_inputBufferL[bufferOffset] = 128.0f * (static_cast<float>(samples[0 + i * channels]) - float(signalOffset)) / float(signalAmplitude);
        if (channels > 1)
        {
            m_inputBufferR[bufferOffset] = 128.0f * (static_cast<float>(samples[1 + i * channels]) - float(signalOffset)) / float(signalAmplitude);
        }
        else
        {
            m_inputBufferR[bufferOffset] = m_inputBufferL[bufferOffset];
        }
    }
    m_start = (m_start + sampleCount) % AudioBufferSamples;
}

void PCM::Add(float const* const samples, uint32_t channels, size_t const count)
{
    AddToBuffer<1, 0>(samples, channels, count);
}
void PCM::Add(uint8_t const* const samples, uint32_t channels, size_t const count)
{
    AddToBuffer<128, 128>(samples, channels, count);
}
void PCM::Add(int16_t const* const samples, uint32_t channels, size_t const count)
{
    AddToBuffer<32768, 0>(samples, channels, count);
}

void PCM::UpdateFrameAudioData(double secondsSinceLastFrame, uint32_t frame)
{
    // 1. Copy audio data from input buffer
    CopyNewWaveformData(m_inputBufferL, m_waveformL);
    CopyNewWaveformData(m_inputBufferR, m_waveformR);

    // 2. Compute raw FFT spectrum for both channels
    UpdateSpectrum(m_waveformL, m_spectrumRawL);
    UpdateSpectrum(m_waveformR, m_spectrumRawR);

    // 3. Temporal smoothing: fast attack (respond to beats), slow decay (remove jitter).
    //    Attack coeff ~0.35 means 65% of a new transient comes through immediately.
    //    Decay coeff  ~0.78 means noise fades at ~22% per frame (~30fps = smooth in ~150ms).
    SmoothSpectrum(m_spectrumRawL, m_spectrumL, secondsSinceLastFrame);
    SmoothSpectrum(m_spectrumRawR, m_spectrumR, secondsSinceLastFrame);

    // 4. Align waveforms
    m_alignL.Align(m_waveformL);
    m_alignR.Align(m_waveformR);

    // 5. Update beat detection values (uses smoothed spectrum)
    m_bass.Update(m_spectrumL, secondsSinceLastFrame, frame);
    m_middles.Update(m_spectrumL, secondsSinceLastFrame, frame);
    m_treble.Update(m_spectrumL, secondsSinceLastFrame, frame);

}

auto PCM::GetFrameAudioData() const -> FrameAudioData
{
    FrameAudioData data{};

    std::copy(m_waveformL.begin(), m_waveformL.begin() + WaveformSamples, data.waveformLeft.begin());
    std::copy(m_waveformR.begin(), m_waveformR.begin() + WaveformSamples, data.waveformRight.begin());
    std::copy(m_spectrumL.begin(), m_spectrumL.begin() + SpectrumSamples, data.spectrumLeft.begin());
    std::copy(m_spectrumR.begin(), m_spectrumR.begin() + SpectrumSamples, data.spectrumRight.begin());

    data.bass = m_bass.CurrentRelative();
    data.mid = m_middles.CurrentRelative();
    data.treb = m_treble.CurrentRelative();

    data.bassAtt = m_bass.AverageRelative();
    data.midAtt = m_middles.AverageRelative();
    data.trebAtt = m_treble.AverageRelative();

    data.vol = (data.bass + data.mid + data.treb) * 0.333f;
    data.volAtt = (data.bassAtt + data.midAtt + data.trebAtt) * 0.333f;

    return data;
}

void PCM::UpdateSpectrum(const WaveformBuffer& waveformData, SpectrumBuffer& spectrumData)
{
    // Feed waveform directly into the FFT.  The MilkdropFFT sine envelope
    // already acts as a proper Hann window to suppress spectral leakage.
    // The old 2-tap low-pass filter (y[n] = 0.5*(x[n]+x[n-1])) was redundant
    // with that window and severely attenuated treble (6-23 dB roll-off).
    std::vector<float> waveformSamples(waveformData.begin(),
                                       waveformData.begin() + AudioBufferSamples);
    std::vector<float> spectrumValues;

    m_fft.TimeToFrequencyDomain(waveformSamples, spectrumValues);

    std::copy(spectrumValues.begin(), spectrumValues.end(), spectrumData.begin());
}

void PCM::SmoothSpectrum(const SpectrumBuffer& raw, SpectrumBuffer& smoothed,
                         double secondsSinceLastFrame)
{
    // Per-bin exponential moving average.
    // Fast attack so transients (snares, hi-hats) punch through immediately.
    // Slow decay so the spectrum doesn't jitter between frames.
    //
    // Base rates are tuned for 30 fps; AdjustRate scales them to actual fps.
    constexpr float kAttackRate = 0.35f; // ~65% of new value on rising edge
    constexpr float kDecayRate  = 0.55f; // ~45% of new value on falling edge (~0.5s to silence)

    float const perSecondAttack = std::pow(kAttackRate, 30.0f);
    float const perSecondDecay  = std::pow(kDecayRate, 30.0f);
    float const dt = static_cast<float>(secondsSinceLastFrame);
    float const attackCoeff = std::pow(perSecondAttack, dt);
    float const decayCoeff  = std::pow(perSecondDecay, dt);

    for (size_t i = 0; i < SpectrumSamples; i++)
    {
        float coeff = (raw[i] > smoothed[i]) ? attackCoeff : decayCoeff;
        smoothed[i] = smoothed[i] * coeff + raw[i] * (1.0f - coeff);
    }
}

void PCM::CopyNewWaveformData(const WaveformBuffer& source, WaveformBuffer& destination)
{
    auto const bufferStartIndex = m_start.load();

    for (size_t i = 0; i < AudioBufferSamples; i++)
    {
        destination[i] = source[(bufferStartIndex + i) % AudioBufferSamples];
    }
}


} // namespace Audio
} // namespace libprojectM
