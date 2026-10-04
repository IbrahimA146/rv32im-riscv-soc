/*
 * i_sound_stub.c - silent sound backend
 *
 * The SoC has no audio device, and doomgeneric's own i_sound.c is built on
 * SDL_mixer. This provides the same interface with everything stubbed out, so
 * the rest of DOOM links and runs unchanged (it still tracks sound state, it
 * just never hears anything).
 */
#include "doomtype.h"
#include "i_sound.h"
#include "m_config.h"

// Configuration variables the rest of the game reads.
int   snd_sfxdevice      = SNDDEVICE_SB;
int   snd_musicdevice    = SNDDEVICE_NONE;
int   snd_samplerate     = 44100;
int   snd_cachesize      = 64 * 1024 * 1024;
int   snd_maxslicetime_ms = 28;
char *snd_musiccmd       = "";
int   snd_pitchshift     = 0;

void I_InitSound(boolean use_sfx_prefix)      { (void)use_sfx_prefix; }
void I_ShutdownSound(void)                    { }
int  I_GetSfxLumpNum(sfxinfo_t *s)            { (void)s; return 0; }
void I_UpdateSound(void)                      { }
void I_UpdateSoundParams(int c, int v, int s) { (void)c; (void)v; (void)s; }
int  I_StartSound(sfxinfo_t *s, int c, int v, int sep)
{
    (void)s; (void)c; (void)v; (void)sep;
    return 0;
}
void    I_StopSound(int channel)              { (void)channel; }
boolean I_SoundIsPlaying(int channel)         { (void)channel; return false; }
void    I_PrecacheSounds(sfxinfo_t *s, int n) { (void)s; (void)n; }
void    I_SetSfxVolume(int volume)            { (void)volume; }

void    I_InitMusic(void)                     { }
void    I_ShutdownMusic(void)                 { }
void    I_SetMusicVolume(int volume)          { (void)volume; }
void    I_PauseSong(void)                     { }
void    I_ResumeSong(void)                    { }
void   *I_RegisterSong(void *data, int len)   { (void)data; (void)len; return NULL; }
void    I_UnRegisterSong(void *handle)        { (void)handle; }
void    I_PlaySong(void *handle, boolean loop) { (void)handle; (void)loop; }
void    I_StopSong(void)                      { }
boolean I_MusicIsPlaying(void)                { return false; }

void I_BindSoundVariables(void)
{
    M_BindVariable("snd_sfxdevice",   &snd_sfxdevice);
    M_BindVariable("snd_musicdevice", &snd_musicdevice);
    M_BindVariable("snd_samplerate",  &snd_samplerate);
}
