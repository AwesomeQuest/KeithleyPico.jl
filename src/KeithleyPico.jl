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
# global MAX_CURRENT::Float64 = 1.0
# global MIN_RESISTANCE::Float64 = 0.1

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

	write(KEITHLY, "OUTP ON")
	write(KEITHLY, "SENS:CURR:PROT $(min(INPUT_VOLTAGE/MIN_RESISTANCE, MAX_CURRENT))")
	write(KEITHLY, "SOUR:VOLT $INPUT_VOLTAGE")
	while monitoring_keithley
		starttime = now()
		voltage,current = nothing, nothing
		try
			voltage,current = reinterpret(Float32, query(KEITHLY, "MEAS:CURR?"; delay=0.01)[3:end] |> codeunits)
		catch
			continue
		end
		push!(keithley_rt_measurment_time, starttime)
		push!(keithley_rt_measurment_x, voltage)
		push!(keithley_rt_measurment_y, current)
		now() - starttime < keithley_sample_period && autosleep(keithley_sample_period - (now() - starttime))
	end
	write(KEITHLY, "OUTP OFF")
end

function keithly_sweep(minvoltage, maxvoltage, stepvoltage, initialvoltage, direction, sweeptime::Nano)
	iv_sweeping_bool = true
	write(KEITHLY, "OUTP ON")
	write(KEITHLY, "SENS:CURR:PROT $(min(INPUT_VOLTAGE/MIN_RESISTANCE, MAX_CURRENT))")
	empty!(keithley_iv_measurment_time)
	empty!(keithley_iv_measurment_x)
	empty!(keithley_iv_measurment_y)
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
		write(KEITHLY, "SOUR:VOLT $voltage")
		now() - currtime < steptime && autosleep(steptime - (now() - currtime))
		actvoltage,current = nothing, nothing
		try
			actvoltage,current = reinterpret(Float32, query(KEITHLY, "MEAS:CURR?"; delay=0.01)[3:end] |> codeunits)
		catch
			continue
		end
		push!(keithley_iv_measurment_time, now())
		push!(keithley_iv_measurment_x, actvoltage)
		push!(keithley_iv_measurment_y, current)
	end
	write(KEITHLY, "OUTP OFF")
	iv_sweeping_bool = false
end


function (@main)(ARGS)
	global TIMESTAMP_MODE
	global keithley_sample_period
	global monitoring_keithley

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
	ivsweep_x = [xs; reverse(xs)]
	ivsweep_time = fill(now(), length(ivsweep_x)) .+ micros.(1:length(ivsweep_x))
	ivsweep_y = [x + 2x^3 for x in ivsweep_x] .+ cumsum(0.05(rand(length(ivsweep_x)) .- 0.5))
	iv_sweeping_bool = false
	iv_cancel_sweep = false
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
			now() - currtime < steptime && autosleep(steptime - (now() - currtime))
		end
		iv_sweeping_bool = false
	end

	rt_xflags = ImPlot.ImPlotAxisFlags_None | ImPlot.ImPlotAxisFlags_AutoFit | ImPlot.ImPlotAxisFlags_RangeFit
	rt_yflags = ImPlot.ImPlotAxisFlags_None | ImPlot.ImPlotAxisFlags_AutoFit
	realtime_time = fill(now(), 1000) .+ micros.(1:1000)
	realtime_x = collect(1:1000)
	realtime_y = cumsum(rand(1000) .-0.5)
	rt_set_volts::Float32 = 1.0f0
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
			now() - starttime < keithley_sample_period && autosleep(keithley_sample_period - (now() - starttime))
		end
	end
	errormonitor(Threads.@async livedata())

	
	ig.set_backend(:GlfwOpenGL3)

	ctx = ig.CreateContext()
	io = ig.GetIO()
	io.ConfigDpiScaleFonts = true
	io.ConfigDpiScaleViewports = true
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
				@c ig.CheckboxFlags("Range Fit X-Axis##rt", &iv_xflags, ImPlot.ImPlotAxisFlags_RangeFit)
				ig.SameLine()
				@c ig.CheckboxFlags("Range Fit Y-Axis##rt", &iv_yflags, ImPlot.ImPlotAxisFlags_RangeFit)
				if ImPlot.BeginPlot("Foo", "x1", "y1", ig.ImVec2(800, 800))
					ImPlot.SetupAxes("Voltage", "Current", iv_xflags, iv_yflags)
					ImPlot.PlotLine("data", ivsweep_x, ivsweep_y)
					ImPlot.EndPlot()
				end
				ig.SameLine()
				ig.BeginGroup()
				ig.PushFont(C_NULL, 15.0f0)
				if ig.Button("Clear Data##iv", (250,50)) && !iv_sweeping_bool
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
					if ig.Button("I'm sure I want to perminently erase data.")
						empty!(ivsweep_time)
						empty!(ivsweep_x)
						empty!(ivsweep_y)
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
					ig.Text("$(isempty(ivsweep_y) ? "NAN" : round(maximum(ivsweep_y), sigdigits=5))")
					ig.TableSetColumnIndex(1)
					ig.Text("$(isempty(ivsweep_y) ? "NAN" : round(minimum(ivsweep_y), sigdigits=5))")
					ig.EndTable()
				end
				ig.PopStyleVar()
				
				if ig.Button("Save Data##iv", (250,50)) && !iv_sweeping_bool
					filepath = save_file(;filterlist="csv")
					if !isempty(filepath)
						open(filepath, "w") do io
							isempty(ivsweep_time) && return
							time = copy(ivsweep_time)
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
							writedlm(io, [time ivsweep_x ivsweep_y], ',')
						end
					end
				end
				if iv_sweeping_bool
					if ig.BeginItemTooltip()
						ig.TextColored((255,0,0,255), "You cannot save data during a sweep")
						ig.EndTooltip()
					end
				end
				
				ig.PushItemWidth(150.0f0)
				@c ig.DragFloat("Minimum Voltage", &iv_min_volts, 0.01f0)
				# ig.SameLine()
				@c ig.DragFloat("Maximum Voltage", &iv_max_volts, 0.01f0)
				@c ig.DragFloat("Step Voltage", &iv_step_voltage, 0.001f0)
				@c ig.DragFloat("Sweep time", &iv_sweep_time, 0.01f0)
				ig.SameLine()
				ig.SetNextItemWidth(200.0f0)
				@c ig.Combo("##01", &iv_time_units, ["Seconds", "Minutes", "Hours"])
				@c ig.DragFloat("Initial Voltage", &iv_init_voltage, 0.001f0)
				# ig.SameLine()
				ig.SetNextItemWidth(500.0f0)
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
					if ig.Button("I'm sure I want to perminently erase data and start a new sweep.")
						iv_cancel_sweep = false
						unitvec = [seconds, minutes, hours]
						sweeptime = unitvec[iv_time_units+1](iv_sweep_time)
						errormonitor(Threads.@async start_iv_sweep(iv_min_volts, iv_max_volts, iv_step_voltage, iv_init_voltage, iv_sweep_dir, sweeptime))
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
				@c ig.CheckboxFlags("Range Fit X-Axis##rt", &rt_xflags, ImPlot.ImPlotAxisFlags_RangeFit)
				ig.SameLine()
				@c ig.CheckboxFlags("Range Fit Y-Axis##rt", &rt_yflags, ImPlot.ImPlotAxisFlags_RangeFit)
				if ImPlot.BeginPlot("Foo", "x1", "y1", ig.ImVec2(800, 800))
					ImPlot.SetupAxes("Time", "Current", rt_xflags, rt_yflags)
					ImPlot.PlotLine("realtime", realtime_x, realtime_y)
					ImPlot.EndPlot()
				end
				ig.SameLine()
				ig.BeginGroup()
				ig.PushFont(C_NULL, 15.0f0)
				if ig.Button("Clear Data", (250,50))
					ig.OpenPopup("clear_data_popup")
				end
				if ig.BeginPopup("clear_data_popup")
					ig.SeparatorText("Are you sure you want to erase the data?")
					ig.SeparatorText("")
					if ig.Button("I'm sure I want to perminently erase data.")
						empty!(realtime_time)
						empty!(realtime_x)
						empty!(realtime_y)
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
					ig.Text("$(isempty(realtime_y) ? "NAN" : round(maximum(realtime_y), sigdigits=5))")
					ig.TableSetColumnIndex(1)
					ig.Text("$(isempty(realtime_y) ? "NAN" : round(minimum(realtime_y), sigdigits=5))")
					ig.TableSetColumnIndex(2)
					ig.Text("$(isempty(realtime_y) ? "NAN" : round(mean(realtime_y), sigdigits=5))")
					ig.EndTable()
				end
				ig.PopStyleVar()

				if ig.Button("Save Data##rt", (250,50))
					old_monitoring = monitoring_keithley
					monitoring_keithley = false
					filepath = save_file(;filterlist="csv")
					if !isempty(filepath)
						open(filepath, "w") do io
							isempty(realtime_time) && return
							time = copy(realtime_time)
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
							writedlm(io, [time realtime_x realtime_y], ',')
						end
					end
					monitoring_keithley = old_monitoring
				end
				
				ig.PushItemWidth(150.0f0)
				@c ig.DragFloat("Set Voltage", &rt_set_volts, 0.001f0)
				@c ig.DragFloat("Sample rate", &rt_smpl_rate, 0.1f0)
				ig.SameLine()
				ig.SetNextItemWidth(250.0f0)
				@c ig.Combo("##rt_smpl_units", &rt_smpl_rate_unit, ["Micro Seconds", "Milli Seconds", "Seconds", "Minutes", "Hours", "Hz", "kHz"])
				units = [micros, millis, seconds, minutes, hours, Hz, kHz]
				keithley_sample_period = units[rt_smpl_rate_unit+1](rt_smpl_rate)
				ig.PopItemWidth()
				ig.PopFont()
				
				ig.PushFont(C_NULL, 20.0f0)
				if !monitoring_keithley
					if !isempty(realtime_x)
						if ig.Button("Resume", (250,50)) && !iv_sweeping_bool
							monitoring_keithley = !monitoring_keithley
							rt_prev_set_volts = rt_set_volts
						end
					elseif ig.Button("Start", (250,50)) && !iv_sweeping_bool
						monitoring_keithley = !monitoring_keithley
						rt_prev_set_volts = rt_set_volts
					end
				else
					if ig.Button("Stop", (250,50))
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
		
		ig.End()
	end

	
	# write(KEITHLY, "OUTP OFF")
	# Instruments.disconnect!(KEITHLY)
end


end # module KeithleyPico
