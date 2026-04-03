module KeithleyPico

using NativeFileDialog, DelimitedFiles
using Statistics

import CImGui as ig, ModernGL, GLFW
import CSyntax: @c
import ImPlot

include("BetterSleep.jl")
using .BetterSleep
import .BetterSleep: now
using Dates
using TimesDates

using Instruments

global keithley_sample_period::Nano = seconds(0.01)
global keithley_realtime_data::Vector{Tuple{Nano, Float32, Float32}} = Tuple{Nano, Float32, Float32}[]
global monitoring_keithley = false
# global INPUT_VOLTAGE::Float64 = 1.0
global MAX_CURRENT::Float64 = 1.0
# global MIN_RESISTANCE::Float64 = 0.1
global rt_set_volts::Float32 = 1.0f0

# global const TIMESTART::DateTime = now()
#= Possible modes 
	:datetime
	:seconds
	:delta
=#
global TIMESTAMP_MODE::Symbol = :datetime

# function normalizetime(time)
# 	Microsecond(time)*10e6
# end

function initialize_keithly()
	global RESMNGR = ResourceManager()
	@show instruments = find_resources(RESMNGR) # returns a list of VISA strings for all found instruments
	global KEITHLY = GenericInstrument()
	Instruments.connect!(RESMNGR, KEITHLY, "GPIB0::24::INSTR")
	@info query(KEITHLY, "*IDN?") # prints "Rohde&Schwarz,SMIQ...."

	write(KEITHLY, "*RST")
	write(KEITHLY, "SOUR:FUNC VOLT")
	write(KEITHLY, "SENS:FUNC 'CURR'")
	write(KEITHLY, "FORM:DATA REAL,32")
	write(KEITHLY, "FORM:BORD SWAP")
end

function keithly_monitor()
	global keithley_sample_period
	global monitoring_keithley
	global keithley_rt_measurment_time
	global keithley_rt_measurment_volts
	global keithley_rt_measurment_current
	global KEITHLY
	global rt_set_volts

	@warn "Starting monitor"
	write(KEITHLY, "OUTP ON")
	write(KEITHLY, "SENS:CURR:PROT $(MAX_CURRENT)")
	@info "SOUR:VOLT $(rt_set_volts)"
	write(KEITHLY, "SOUR:VOLT $(rt_set_volts)")
	while monitoring_keithley
		starttime = now()
		voltage,current = nothing, nothing
		try
			voltage,current = reinterpret(Float32, query(KEITHLY, "MEAS:CURR?"; delay=0.01)[3:end] |> codeunits)
		catch e
			# @error e
			continue
		end
		push!(keithley_rt_measurment_time, starttime)
		push!(keithley_rt_measurment_volts, voltage)
		push!(keithley_rt_measurment_current, current)
		while now() - starttime < keithley_sample_period
			if now() - starttime < keithley_sample_period > millis(100)
				autosleep(millis(100))
			else
				autosleep(keithley_sample_period - (now() - starttime))
				break
			end
		end
	end
	write(KEITHLY, "OUTP OFF")
end

function keithly_sweep(minvoltage, maxvoltage, stepvoltage, initialvoltage, direction, sweeptime::Nano)
	global iv_cancel_sweep
	global keithley_iv_measurment_time
	global keithley_iv_measurment_voltage
	global keithley_iv_measurment_current
	global KEITHLY
	
	global iv_sweeping_bool = true
	write(KEITHLY, "OUTP ON")
	write(KEITHLY, "SENS:CURR:PROT $(MAX_CURRENT)")
	empty!(keithley_iv_measurment_time)
	empty!(keithley_iv_measurment_voltage)
	empty!(keithley_iv_measurment_current)
	if minvoltage > maxvoltage
		minvoltage, maxvoltage = maxvoltage, minvoltage
	end
	volts = minvoltage:stepvoltage:maxvoltage
	volts = [(minvoltage:stepvoltage:maxvoltage); (maxvoltage:-stepvoltage:minvoltage); minvoltage]
	pivot = sortperm(abs.(volts .- initialvoltage)) |> first
	volts = volts[direction == 0 ? [pivot:end; 1:pivot] : [pivot:-1:1; end:-1:pivot-2]]
	steptime = sweeptime/length(volts)
	for (i, voltage) in enumerate(volts)
		iv_cancel_sweep && break
		currtime = now()
		@info "SOUR:VOLT $voltage"
		write(KEITHLY, "SOUR:VOLT $voltage")
		if now() - currtime < steptime
			while !iv_cancel_sweep
				if steptime - (now() - currtime) > millis(100)
					autosleep(millis(100))
				else
					autosleep(steptime - (now() - currtime))
					break
				end
			end
		end
		actvoltage,current = nothing, nothing
		try
			actvoltage,current = reinterpret(Float32, query(KEITHLY, "MEAS:CURR?"; delay=0.01)[3:end] |> codeunits)
		catch e
			# @error e
			continue
		end
		push!(keithley_iv_measurment_time, now())
		push!(keithley_iv_measurment_voltage, actvoltage)
		push!(keithley_iv_measurment_current, current)
	end
	write(KEITHLY, "OUTP OFF")
	iv_sweeping_bool = false
end


function (@main)(ARGS)
	global TIMESTAMP_MODE
	global keithley_sample_period
	global monitoring_keithley
	global rt_set_volts

	initialize_keithly()

	iv_xflags = ImPlot.ImPlotAxisFlags_None | ImPlot.ImPlotAxisFlags_AutoFit
	iv_yflags = ImPlot.ImPlotAxisFlags_None | ImPlot.ImPlotAxisFlags_AutoFit
	iv_min_volts::Float32	= -1.0
	iv_max_volts::Float32	= 1.0
	iv_step_voltage::Float32= 0.01
	iv_sweep_time::Float32	= 1.0
	iv_time_units::Int32	= 0
	iv_init_voltage::Float32=0.0f0
	iv_sweep_dir::Int32		= 0
	xs = iv_min_volts:iv_step_voltage:iv_max_volts
	global keithley_iv_measurment_time	= Nano[]
	global keithley_iv_measurment_voltage	= Float32[]
	global keithley_iv_measurment_current	= Float32[]
	global iv_sweeping_bool = false
	global iv_cancel_sweep = false
	function start_iv_sweep(minvoltage, maxvoltage, stepvoltage, initialvoltage, direction, sweeptime::Nano)
		iv_sweeping_bool = true
		empty!(ivsweep_time)
		empty!(ivsweep_x)
		empty!(ivsweep_y)
		if minvoltage > maxvoltage
			minvoltage, maxvoltage = maxvoltage, minvoltage
		end
		volts = minvoltage:stepvoltage:maxvoltage
		volts = [(minvoltage:stepvoltage:maxvoltage); (maxvoltage:-stepvoltage:minvoltage); minvoltage]
		pivot = sortperm(abs.(volts .- initialvoltage)) |> first
		volts = volts[direction == 0 ? [pivot:end; 1:pivot] : [pivot:-1:1; end:-1:pivot-2]]
		noisevector = cumsum(0.05(rand(length(volts)) .- 0.5))
		steptime = sweeptime/length(volts)
		for (i, voltage) in enumerate(volts)
			iv_cancel_sweep && break
			currtime = now()
			push!(ivsweep_time, now())
			push!(ivsweep_x, voltage)
			push!(ivsweep_y, voltage + 2voltage^3 + noisevector[i])
			if now() - currtime < steptime
				while !iv_cancel_sweep
					if steptime - (now() - currtime) > millis(100)
						autosleep(millis(100))
					else
						autosleep(steptime - (now() - currtime))
						break
					end
				end
			end
		end
		iv_sweeping_bool = false
	end

	rt_xflags = ImPlot.ImPlotAxisFlags_None | ImPlot.ImPlotAxisFlags_AutoFit | ImPlot.ImPlotAxisFlags_RangeFit
	rt_yflags = ImPlot.ImPlotAxisFlags_None | ImPlot.ImPlotAxisFlags_AutoFit
	global keithley_rt_measurment_time = Nano[]
	global keithley_rt_measurment_volts = Float32[]
	global keithley_rt_measurment_current = Float32[]
	rt_prev_set_volts::Float32 = 1.0f0
	rt_smpl_rate::Float32 = 1.0f0
	rt_smpl_rate_unit::Int32 = 0
	function livedata()
		while true
			starttime = now()
			if monitoring_keithley
				if isempty(realtime_x)
					push!(realtime_time, now())
					push!(realtime_x, 1)
					push!(realtime_y, rand()-0.5)
				end
				push!(realtime_time, now())
				push!(realtime_x, realtime_x[end]+1)
				push!(realtime_y, realtime_y[end]+rand()-0.5)
			end
			while now() - starttime < keithley_sample_period
				if now() - starttime < keithley_sample_period > millis(100)
					autosleep(millis(100))
				else
					autosleep(keithley_sample_period - (now() - starttime))
					break
				end
			end
		end
	end
	# errormonitor(Threads.@async livedata())

	
	ig.set_backend(:GlfwOpenGL3)

	ctx = ig.CreateContext()
	io = ig.GetIO()
	# io.ConfigDpiScaleFonts = true
	# io.ConfigDpiScaleViewports = true
	io.ConfigFlags = unsafe_load(io.ConfigFlags) | ig.lib.ImGuiConfigFlags_DockingEnable
	io.ConfigFlags = unsafe_load(io.ConfigFlags) | ig.lib.ImGuiConfigFlags_ViewportsEnable
	style = ig.GetStyle()
	p_ctx = ImPlot.CreateContext()

	show_plot_style_editor = false
	show_imgui_style_editor = false

	exit_application_bool = true
	first_frame = true
	ig.render(ctx; window_size=(1,1), window_title="Keithley Pico", on_exit=() -> ImPlot.DestroyContext(p_ctx)) do
		!exit_application_bool && exit()

		DPI = ig.GetWindowDpiScale()
		ig.PushFont(C_NULL, 15.0f0DPI*unsafe_load(style.FontScaleDpi))
		if first_frame
			win = ig._current_window(Val{:GlfwOpenGL3}())
			GLFW.HideWindow(win)
		end
		first_frame = false

		if show_plot_style_editor
			ig.Begin("Plot Style Editor")
			ImPlot.ShowStyleEditor(ImPlot.GetStyle())
			ig.End()
		end
		if show_imgui_style_editor
			ig.Begin("ImGui Style Editor")
			ig.ShowStyleEditor()
			ig.End()
		end

		@c ig.Begin("Plot Window", &exit_application_bool,
			ig.ImGuiWindowFlags_MenuBar |
			ig.ImGuiWindowFlags_NoCollapse |
			ig.ImGuiWindowFlags_AlwaysAutoResize)

		if (ig.BeginMenuBar())
			if (ig.BeginMenu("Tools"))
				@c ig.MenuItem("Show Plot Style Editor", "", &show_plot_style_editor)
				@c ig.MenuItem("Show ImGui Style Editor", "", &show_imgui_style_editor)
				ig.DragFloat("Window size##tools", style.FontScaleDpi, 0.001f0, 0.001f0, 4.0f0)
				ig.EndMenu();
			end
			if ig.BeginMenu("Units")
				if ig.TreeNode("Time Units")
					selected = TIMESTAMP_MODE === :datetime ? 1 : TIMESTAMP_MODE === :seconds ? 2 : TIMESTAMP_MODE === :delta ? 3 : -1
					ig.Selectable("DateTime Timestamps", selected === 1) && (selected = 1)
					ig.Selectable("Seconds since start of capture", selected === 2) && (selected = 2)
					ig.Selectable("Seconds since last capture", selected === 3) && (selected = 3)
	
					TIMESTAMP_MODE = [:datetime, :seconds, :delta][selected]
					ig.TreePop()
				end
				ig.EndMenu()
			end
			ig.EndMenuBar();
		end

		if ig.BeginTabBar("MyTabBar", ig.ImGuiTabBarFlags_NoCloseWithMiddleMouseButton)
			if ig.BeginTabItem("I-V Sweep")
				# ImPlot.SetNextAxesToFit()
				@c ig.CheckboxFlags("Fit X-Axis##rt", &iv_xflags, ImPlot.ImPlotAxisFlags_AutoFit)
				ig.SameLine()
				@c ig.CheckboxFlags("Fit Y-Axis##rt", &iv_yflags, ImPlot.ImPlotAxisFlags_AutoFit)
				if (iv_xflags | iv_yflags) & ImPlot.ImPlotAxisFlags_AutoFit != 0
					if (iv_xflags & iv_yflags) & ImPlot.ImPlotAxisFlags_AutoFit != 0
						iv_xflags = iv_xflags & ~ImPlot.ImPlotAxisFlags_RangeFit
						iv_yflags = iv_yflags & ~ImPlot.ImPlotAxisFlags_RangeFit
					else
						ig.SameLine()
						if iv_xflags & ImPlot.ImPlotAxisFlags_AutoFit != 0
							@c ig.CheckboxFlags("Range Fit##rt", &iv_xflags, ImPlot.ImPlotAxisFlags_RangeFit)
						else
							@c ig.CheckboxFlags("Range Fit##rt", &iv_yflags, ImPlot.ImPlotAxisFlags_RangeFit)
						end
					end
				end
				if ImPlot.BeginPlot("I-V Sweep", "Voltage", "Current", ig.ImVec2(400DPI*unsafe_load(style.FontScaleDpi), 400DPI*unsafe_load(style.FontScaleDpi)))
					ImPlot.SetupAxes("Voltage", "Current", iv_xflags, iv_yflags)
					if !isempty(keithley_iv_measurment_current)
						ImPlot.PlotLine("data", keithley_iv_measurment_voltage, keithley_iv_measurment_current)
					end
					ImPlot.EndPlot()
				end
				ig.SameLine()
				ig.BeginGroup()
				ig.PushFont(C_NULL, 15.0f0DPI*unsafe_load(style.FontScaleDpi))
				if ig.Button("Clear Data##iv", (180DPI*unsafe_load(style.FontScaleDpi),30DPI*unsafe_load(style.FontScaleDpi))) && !iv_sweeping_bool
					ig.OpenPopup("clear_data_popup##iv")
				end
				if iv_sweeping_bool
					if ig.BeginItemTooltip()
						ig.TextColored((255,0,0,255), "You Cannot clear data during a sweep")
						ig.EndTooltip()
					end
				end
				if ig.BeginPopup("clear_data_popup##iv")
					ig.SeparatorText("Are you sure you want to erase the data?")
					ig.SeparatorText("")
					if ig.Button("I'm sure I want to permanently erase data.")
						empty!(keithley_iv_measurment_time)
						empty!(keithley_iv_measurment_voltage)
						empty!(keithley_iv_measurment_current)
						ig.CloseCurrentPopup()
					end
					ig.EndPopup()
				end

				ig.PushStyleVar(ig.lib.ImGuiStyleVar_CellPadding, (3,3))
				if ig.BeginTable("iv_maxmin_table", 2, ig.lib.ImGuiTableFlags_RowBg | ig.lib.ImGuiTableFlags_Borders | ig.lib.ImGuiTableFlags_SizingStretchSame)
					ig.TableSetupColumn("Maximum [A]")
					ig.TableSetupColumn("Minimum [A]")
					ig.TableHeadersRow()
					ig.TableNextRow()
					ig.TableSetColumnIndex(0)
					ig.Text("$(isempty(keithley_iv_measurment_current) ? "NAN" : round(maximum(keithley_iv_measurment_current), sigdigits=5))")
					ig.TableSetColumnIndex(1)
					ig.Text("$(isempty(keithley_iv_measurment_current) ? "NAN" : round(minimum(keithley_iv_measurment_current), sigdigits=5))")
					ig.EndTable()
				end
				ig.PopStyleVar()
				
				if ig.Button("Save Data##iv", (180DPI*unsafe_load(style.FontScaleDpi),30DPI*unsafe_load(style.FontScaleDpi))) && !iv_sweeping_bool
					filepath = save_file(;filterlist="csv")
					if !isempty(filepath)
						open(filepath, "w") do io
							isempty(keithley_iv_measurment_time) && return
							time = copy(keithley_iv_measurment_time)
							if TIMESTAMP_MODE === :datetime
								timedatenow, nanonow = TimeDate(Dates.now()), BetterSleep.now()
								synthetic_first_time = timedatenow - Nanosecond((nanonow - time[1]).ns)
								time = [synthetic_first_time + Nanosecond((tt - time[1]).ns) for tt in time]
								timeunit = "[DateTime]"
							elseif TIMESTAMP_MODE === :seconds
								time = (time .- [time[1]]) .|> x->x.ns/1e9
								timeunit = "[seconds]"
							elseif TIMESTAMP_MODE === :delta
								lasttime = time[1]
								time[1] = Nano(0)
								for i in eachindex(time)
									i == 1 && continue
									lasttime, time[i] = time[i], lasttime - time[i]
								end
								time = time .|> x->x.ns/1e9
								timeunit = "[seconds]"
							else
								time = time .|> x->x.ns
								timeunit = "[Nanoseconds]"
							end
							writedlm(io, ["TimeStamp "*timeunit "Voltage" "Current"], ',')
							writedlm(io, [time keithley_iv_measurment_voltage keithley_iv_measurment_current], ',')
						end
					end
				end
				if iv_sweeping_bool
					if ig.BeginItemTooltip()
						ig.TextColored((255,0,0,255), "You cannot save data during a sweep")
						ig.EndTooltip()
					end
				end
				
				ig.PushItemWidth(70.0f0DPI*unsafe_load(style.FontScaleDpi))
				@c ig.DragFloat("Minimum Voltage", &iv_min_volts, 0.01f0)
				# ig.SameLine()
				@c ig.DragFloat("Maximum Voltage", &iv_max_volts, 0.01f0)
				@c ig.DragFloat("Step Voltage", &iv_step_voltage, 0.001f0)
				@c ig.DragFloat("Sweep time", &iv_sweep_time, 0.01f0, 0.01f0, Inf32)
				iv_sweep_time < 0.01f0 && (iv_sweep_time = 0.01f0)
				ig.SameLine()
				ig.SetNextItemWidth(100.0f0DPI*unsafe_load(style.FontScaleDpi))
				@c ig.Combo("##01", &iv_time_units, ["Seconds", "Minutes", "Hours"])
				@c ig.DragFloat("Initial Voltage", &iv_init_voltage, 0.001f0)
				# ig.SameLine()
				ig.SetNextItemWidth(200.0f0DPI*unsafe_load(style.FontScaleDpi))
				@c ig.Combo(" ", &iv_sweep_dir, ["Start Sweep Positive", "Start Sweep Negative"])
				ig.PopItemWidth()

				if !iv_sweeping_bool && ig.Button("Start Sweep") && !monitoring_keithley
					ig.OpenPopup("start_sweep_popup")
				end
				if monitoring_keithley
					if ig.BeginItemTooltip()
						ig.TextColored((255,0,0,255), "You Cannot clear data during a sweep")
						ig.EndTooltip()
					end
				end
				if ig.BeginPopup("start_sweep_popup")
					ig.SeparatorText("Are you sure you want to start a sweep?")
					ig.SeparatorText("Starting a sweep will erase the previous sweep from memory.")
					if ig.Button("I'm sure I want to permanently erase data and start a new sweep.")
						iv_cancel_sweep = false
						unitvec = [seconds, minutes, hours]
						sweeptime = unitvec[iv_time_units+1](iv_sweep_time)
						errormonitor(Threads.@async keithly_sweep(iv_min_volts, iv_max_volts, iv_step_voltage, iv_init_voltage, iv_sweep_dir, sweeptime))
						ig.CloseCurrentPopup()
					end
					ig.EndPopup()
				end
				if iv_sweeping_bool && ig.Button("Cancel Sweep##iv_sweep")
					iv_cancel_sweep = true
				end
				ig.PopFont()
				ig.EndGroup()
				ig.EndTabItem()
			end
			if ig.BeginTabItem("Real Time Monitor")
				@c ig.CheckboxFlags("Fit X-Axis##rt", &rt_xflags, ImPlot.ImPlotAxisFlags_AutoFit)
				ig.SameLine()
				@c ig.CheckboxFlags("Fit Y-Axis##rt", &rt_yflags, ImPlot.ImPlotAxisFlags_AutoFit)
				if (rt_xflags | rt_yflags) & ImPlot.ImPlotAxisFlags_AutoFit != 0
					if (rt_xflags & rt_yflags) & ImPlot.ImPlotAxisFlags_AutoFit != 0
						rt_xflags = rt_xflags & ~ImPlot.ImPlotAxisFlags_RangeFit
						rt_yflags = rt_yflags & ~ImPlot.ImPlotAxisFlags_RangeFit
					else
						ig.SameLine()
						if rt_xflags & ImPlot.ImPlotAxisFlags_AutoFit != 0
							@c ig.CheckboxFlags("Range Fit##rt", &rt_xflags, ImPlot.ImPlotAxisFlags_RangeFit)
						else
							@c ig.CheckboxFlags("Range Fit##rt", &rt_yflags, ImPlot.ImPlotAxisFlags_RangeFit)
						end
					end
				end
				if ImPlot.BeginPlot("Real Time", "Time", "Current", ig.ImVec2(400DPI*unsafe_load(style.FontScaleDpi), 400DPI*unsafe_load(style.FontScaleDpi)))
					ImPlot.SetupAxes("Time", "Current", rt_xflags, rt_yflags)
					if !isempty(keithley_rt_measurment_time)
						ImPlot.PlotLine("realtime_current", keithley_rt_measurment_time, keithley_rt_measurment_current)
					end
					ImPlot.EndPlot()
				end
				ig.SameLine()
				ig.BeginGroup()
				ig.PushFont(C_NULL, 15.0f0DPI*unsafe_load(style.FontScaleDpi))
				if ig.Button("Clear Data", (180DPI*unsafe_load(style.FontScaleDpi),30DPI*unsafe_load(style.FontScaleDpi)))
					ig.OpenPopup("clear_data_popup")
				end
				if ig.BeginPopup("clear_data_popup")
					ig.SeparatorText("Are you sure you want to erase the data?")
					ig.SeparatorText("")
					if ig.Button("I'm sure I want to permanently erase data.")
						empty!(keithley_rt_measurment_time)
						empty!(keithley_rt_measurment_current)
						empty!(keithley_rt_measurment_volts)
						ig.CloseCurrentPopup()
					end
					ig.EndPopup()
				end

				ig.PushStyleVar(ig.lib.ImGuiStyleVar_CellPadding, (3,3))
				if ig.BeginTable("rt_maxmin_table", 3, ig.lib.ImGuiTableFlags_RowBg | ig.lib.ImGuiTableFlags_Borders | ig.lib.ImGuiTableFlags_SizingStretchSame)
					ig.TableSetupColumn("Maximum [A]")
					ig.TableSetupColumn("Minimum [A]")
					ig.TableSetupColumn("Average [A]")
					ig.TableHeadersRow()
					ig.TableNextRow()
					ig.TableSetColumnIndex(0)
					ig.Text("$(isempty(keithley_rt_measurment_current) ? "NAN" : round(maximum(keithley_rt_measurment_current), sigdigits=5))")
					ig.TableSetColumnIndex(1)
					ig.Text("$(isempty(keithley_rt_measurment_current) ? "NAN" : round(minimum(keithley_rt_measurment_current), sigdigits=5))")
					ig.TableSetColumnIndex(2)
					ig.Text("$(isempty(keithley_rt_measurment_current) ? "NAN" : round(mean(keithley_rt_measurment_current), sigdigits=5))")
					ig.EndTable()
				end
				ig.PopStyleVar()

				if ig.Button("Save Data##rt", (180DPI*unsafe_load(style.FontScaleDpi),30DPI*unsafe_load(style.FontScaleDpi)))
					old_monitoring = monitoring_keithley
					monitoring_keithley = false
					filepath = save_file(;filterlist="csv")
					if !isempty(filepath)
						open(filepath, "w") do io
							isempty(keithley_rt_measurment_time) && return
							time = copy(keithley_rt_measurment_time)
							if TIMESTAMP_MODE === :datetime
								timedatenow, nanonow = TimeDate(Dates.now()), BetterSleep.now()
								synthetic_first_time = timedatenow - Nanosecond((nanonow - time[1]).ns)
								time = [synthetic_first_time + Nanosecond((tt - time[1]).ns) for tt in time]
								timeunit = "[DateTime]"
							elseif TIMESTAMP_MODE === :seconds
								time = (time .- [time[1]]) .|> x->x.ns/1e9
								timeunit = "[seconds]"
							elseif TIMESTAMP_MODE === :delta
								lasttime = time[1]
								time[1] = Nano(0)
								for i in eachindex(time)
									i == 1 && continue
									lasttime, time[i] = time[i], lasttime - time[i]
								end
								time = time .|> x->x.ns/1e9
								timeunit = "[seconds]"
							else
								time = time .|> x->x.ns
								timeunit = "[Nanoseconds]"
							end
							writedlm(io, ["TimeStamp "*timeunit "Voltage" "Current"], ',')
							writedlm(io, [time keithley_rt_measurment_volts keithley_rt_measurment_current], ',')
						end
					end
					monitoring_keithley = old_monitoring
				end
				
				ig.PushItemWidth(70.0f0DPI*unsafe_load(style.FontScaleDpi))
				@c ig.DragFloat("Set Voltage", &rt_set_volts, 0.001f0)
				@c ig.DragFloat("Sample rate", &rt_smpl_rate, 0.001f0, 0.001f0, Inf32)
				rt_smpl_rate < 0.001f0 && (rt_smpl_rate = 0.001f0)
				ig.SameLine()
				ig.SetNextItemWidth(125.0f0DPI*unsafe_load(style.FontScaleDpi))
				@c ig.Combo("##rt_smpl_units", &rt_smpl_rate_unit, ["Micro Seconds", "Milli Seconds", "Seconds", "Minutes", "Hours", "Hz", "kHz"])
				units = [micros, millis, seconds, minutes, hours, Hz, kHz]
				keithley_sample_period = units[rt_smpl_rate_unit+1](rt_smpl_rate)
				ig.PopItemWidth()
				ig.PopFont()
				
				ig.PushFont(C_NULL, 20.0f0DPI*unsafe_load(style.FontScaleDpi))
				if !monitoring_keithley
					if !isempty(keithley_rt_measurment_time)
						if ig.Button("Resume", (180DPI*unsafe_load(style.FontScaleDpi),30DPI*unsafe_load(style.FontScaleDpi))) && !iv_sweeping_bool
							monitoring_keithley = !monitoring_keithley
							errormonitor(@async keithly_monitor())
							rt_prev_set_volts = rt_set_volts
						end
					elseif ig.Button("Start", (180DPI*unsafe_load(style.FontScaleDpi),30DPI*unsafe_load(style.FontScaleDpi))) && !iv_sweeping_bool
						monitoring_keithley = !monitoring_keithley
						errormonitor(@async keithly_monitor())
						rt_prev_set_volts = rt_set_volts
					end
				else
					if ig.Button("Stop", (180DPI*unsafe_load(style.FontScaleDpi),30DPI*unsafe_load(style.FontScaleDpi)))
						monitoring_keithley = !monitoring_keithley
					end
				end
				ig.PopFont()
				if iv_sweeping_bool
					# ig.SameLine()
					ig.TextColored((255,0,0,255), "A sweep is currently in progress,\nplese wait for it to finish or cancel it")
				end 
				if rt_prev_set_volts != rt_set_volts
					# ig.SameLine()
					ig.TextColored((255,0,0,255), "Voltage not set, Stop and Resume data collection")
				end
				ig.EndGroup()
				ig.EndTabItem()
			end
			ig.EndTabBar()
		end

		# y = rand(1000)
		# ImPlot.SetNextAxesLimits(0.0,1000,0.0,1.0, ig.ImGuiCond_Once)
		
		ig.PopFont()
		ig.End()
	end

	
	# write(KEITHLY, "OUTP OFF")
	# Instruments.disconnect!(KEITHLY)
end


end # module KeithleyPico
