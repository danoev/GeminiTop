/*
Copyright (C) 1996-1997 Id Software, Inc.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
*/

#include "client.h"
#include "common.h"
#include "console.h"
#include "cvar.h"
#include "input.h"
#include "keys.h"
#include "mathlib.h"
#include "quakedef.h"
#include "vid.h"

qboolean mouseactive;

static qboolean mouse_available;
static qboolean have_focus = true;
static float mouse_x;
static float mouse_y;

static void
windowed_mouse_f(struct cvar_s *var)
{
    mouseactive = mouse_available && have_focus && !!var->value;
}

static cvar_t m_filter = { "m_filter", "0" };
cvar_t _windowed_mouse = {
    .name = "_windowed_mouse",
    .string = "1",
    .flags = CVAR_CONFIG,
    .callback = windowed_mouse_f,
};

void
IN_Gemini_AddMouseMotion(int dx, int dy)
{
    if (!mouse_available || !mouseactive || key_dest != key_game)
        return;

    mouse_x += dx;
    mouse_y += dy;
}

void
IN_SetFocus(qboolean focus)
{
    have_focus = focus;
    mouseactive = mouse_available && have_focus && !!_windowed_mouse.value;
}

qboolean
IN_HaveFocus(void)
{
    return have_focus;
}

void
IN_AddCommands(void)
{
}

void
IN_RegisterVariables(void)
{
    Cvar_RegisterVariable(&m_filter);
    Cvar_RegisterVariable(&_windowed_mouse);
}

void
IN_Init(void)
{
    mouse_available = !COM_CheckParm("-nomouse");
    have_focus = true;
    mouse_x = 0.0f;
    mouse_y = 0.0f;
    mouseactive = mouse_available;
}

void
IN_Shutdown(void)
{
    mouse_x = 0.0f;
    mouse_y = 0.0f;
    mouse_available = false;
    mouseactive = false;
}

void
IN_ClearStates(void)
{
    mouse_x = 0.0f;
    mouse_y = 0.0f;
}

void
IN_ModeChanged(void)
{
    IN_ClearStates();
}

void
IN_Accumulate(void)
{
}

static void
IN_MouseMove(usercmd_t *cmd)
{
    static float old_mouse_x;
    static float old_mouse_y;
    float mx;
    float my;

    if (!mouse_available || !mouseactive)
        return;

    mx = mouse_x;
    my = mouse_y;

    if (m_filter.value) {
        mx = (mx + old_mouse_x) * 0.5f;
        my = (my + old_mouse_y) * 0.5f;
    }

    old_mouse_x = mx;
    old_mouse_y = my;

    mx *= sensitivity.value;
    my *= sensitivity.value;

    if ((in_strafe.state & 1) || (lookstrafe.value && ((in_mlook.state & 1) ^ (int)m_freelook.value)))
        cmd->sidemove += m_side.value * mx;
    else
        cl.viewangles[YAW] -= m_yaw.value * mx;

    if (((in_mlook.state & 1) ^ (int)m_freelook.value) && !(in_strafe.state & 1)) {
        if (mx || my)
            V_StopPitchDrift();
        cl.viewangles[PITCH] += m_pitch.value * my;
        if (cl.viewangles[PITCH] > cl_maxpitch.value)
            cl.viewangles[PITCH] = cl_maxpitch.value;
        if (cl.viewangles[PITCH] < cl_minpitch.value)
            cl.viewangles[PITCH] = cl_minpitch.value;
    } else if ((in_strafe.state & 1) && noclip_anglehack) {
        cmd->upmove -= m_forward.value * my;
    } else {
        cmd->forwardmove -= m_forward.value * my;
    }

    mouse_x = 0.0f;
    mouse_y = 0.0f;
}

void
IN_Move(usercmd_t *cmd)
{
    IN_MouseMove(cmd);
}

void
IN_Commands(void)
{
    if (!mouse_available)
        return;

    mouseactive = have_focus && ((key_dest == key_game && _windowed_mouse.value) || VID_IsFullScreen());
}
