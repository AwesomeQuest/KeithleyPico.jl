module KeithleyPico


import CImGui as ig, ModernGL, GLFW
import CSyntax: @c
import ImPlot

include("BetterSleep.jl")
using .BetterSleep
import .BetterSleep: now

# using Instruments
using Dates

global keithley_sample_period::Nano = seconds(0.01)
global keithley_realtime_data::Vector{Tuple{Nano, Float32, Float32}} = Tuple{Nano, Float32, Float32}[]
# global INPUT_VOLTAGE::Float64 = 1.0
# global MAX_CURRENT::Float64 = 1.0
# global MIN_RESISTANCE::Float64 = 0.1

# global SAMPLE_RATE::Float64 = 10

# global const TIMESTART::DateTime = now()
# global TIMESTAMP_MODE::Symbol = :datetime

# function normalizetime(time)
# 	Microsecond(time)*10e6
# end

# function initialize_keithly()
# 	global RESMNGR = ResourceManager()
# 	@show instruments = find_resources(RESMNGR) # returns a list of VISA strings for all found instruments
# 	global KEITHLY = GenericInstrument()
# 	Instruments.connect!(RESMNGR, KEITHLY, "GPIB0::24::INSTR")
# 	@info query(KEITHLY, "*IDN?") # prints "Rohde&Schwarz,SMIQ...."

# 	write(KEITHLY, "*RST")
# 	write(KEITHLY, "SOUR:FUNC VOLT")
# 	write(KEITHLY, "SENS:FUNC 'CURR'")
# 	write(KEITHLY, "FORM:DATA REAL,32")
# 	write(KEITHLY, "FORM:BORD SWAP")
# 	write(KEITHLY, "OUTP ON")

# 	write(KEITHLY, "SENS:CURR:PROT $(min(INPUT_VOLTAGE/MIN_RESISTANCE, MAX_CURRENT))")
# 	write(KEITHLY, "SOUR:VOLT $INPUT_VOLTAGE")
# end

# function keithlymonitor()
# 	global SAMPLE_RATE
# 	lasttime = now()
# 	while true
# 		timestamp = TIMESTAMP_MODE === :datetime ? now() : TIMESTAMP_MODE === :seconds ? normalizetime(now()-TIMESTART) : normalizetime(now()-lasttime)
# 		voltage,current = nothing, nothing
# 		try
# 			voltage,current = reinterpret(Float32, query(KEITHLY, "MEAS:CURR?"; delay=0.01)[3:end] |> codeunits)
# 		catch
# 			continue
# 		end
# 		sleep(1/SAMPLE_RATE)
# 	end
# end


function (@main)(ARGS)
	
	ig.set_backend(:GlfwOpenGL3)

	ctx = ig.CreateContext()
	io = ig.GetIO()
	io.ConfigDpiScaleFonts = true
	io.ConfigDpiScaleViewports = true
	p_ctx = ImPlot.CreateContext()

	global keithley_sample_period
	monitoring_keithley = false

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
	ivsweep_y = [x + 2x^3 for x in ivsweep_x] .+ cumsum(0.05(rand(length(ivsweep_x)) .- 0.5))
	function start_iv_sweep(minvoltage, maxvoltage, stepvoltage, initialvoltage, direction, sweeptime::Nano)
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
			currtime = now()
			push!(ivsweep_x, voltage)
			push!(ivsweep_y, voltage + 2voltage^3 + noisevector[i])
			now() - currtime < steptime && autosleep(steptime - (now() - currtime))
		end
	end

	rt_xflags = ImPlot.ImPlotAxisFlags_None | ImPlot.ImPlotAxisFlags_AutoFit
	rt_yflags = ImPlot.ImPlotAxisFlags_None | ImPlot.ImPlotAxisFlags_AutoFit
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
					push!(realtime_x, 1)
					push!(realtime_y, rand()-0.5)
				end
				push!(realtime_x, realtime_x[end]+1)
				push!(realtime_y, realtime_y[end]+rand()-0.5)
			end
			autosleep(keithley_sample_period - (now()-starttime))
		end
	end
	errormonitor(Threads.@async livedata())


	show_style_editor = false

	ig.render(ctx; window_size=(1000,1200), window_title="Keithley Pico", on_exit=() -> ImPlot.DestroyContext(p_ctx)) do
		
		if show_style_editor
			ig.Begin("Plot Style Editor")
			ImPlot.ShowStyleEditor(ImPlot.GetStyle())
			ig.End()
		end
		
		ig.SetNextWindowPos((0,0))
		ig.Begin("Plot Window", Ref(true),
			ig.ImGuiWindowFlags_MenuBar |
			ig.ImGuiWindowFlags_NoCollapse |
			ig.ImGuiWindowFlags_AlwaysAutoResize)

		if (ig.BeginMenuBar())
			if (ig.BeginMenu("Tools"))
				@c ig.MenuItem("Show Plot Style Editor", "", &show_style_editor)
				ig.EndMenu();
			end
			ig.EndMenuBar();
		end

		if ig.BeginTabBar("MyTabBar", ig.ImGuiTabBarFlags_NoCloseWithMiddleMouseButton)
			if ig.BeginTabItem("I-V Sweep")
				# ImPlot.SetNextAxesToFit()
				@c ig.CheckboxFlags("Fit X-Axis##rt", &iv_xflags, ImPlot.ImPlotAxisFlags_AutoFit)
				ig.SameLine()
				@c ig.CheckboxFlags("Fit Y-Axis##rt", &iv_yflags, ImPlot.ImPlotAxisFlags_AutoFit)
				if ImPlot.BeginPlot("Foo", "x1", "y1", ig.ImVec2(800, 800))
					ImPlot.SetupAxes("Voltage", "Current", iv_xflags, iv_yflags)
					ImPlot.PlotLine("data", ivsweep_x, ivsweep_y)
					ImPlot.EndPlot()
				end
				ig.PushItemWidth(150.0f0)
				@c ig.DragFloat("Minimum Voltage", &iv_min_volts, 0.01f0)
				ig.SameLine()
				@c ig.DragFloat("Maximum Voltage", &iv_max_volts, 0.01f0)
				@c ig.DragFloat("Step Voltage", &iv_step_voltage, 0.001f0)
				@c ig.DragFloat("Sweep time", &iv_sweep_time, 0.01f0)
				ig.SameLine()
				@c ig.Combo("##01", &iv_time_units, ["Seconds", "Minutes", "Hours"])
				@c ig.DragFloat("Initial Voltage", &iv_init_voltage, 0.001f0)
				ig.SameLine()
				ig.SetNextItemWidth(350.0f0)
				@c ig.Combo(" ", &iv_sweep_dir, ["Start Sweep Positive", "Start Sweep Negative"])
				ig.PopItemWidth()

				if ig.Button("Start Sweep")
					ig.OpenPopup("start_sweep_popup")
				end
				if ig.BeginPopupModal("start_sweep_popup")
					ig.SeparatorText("Are you sure you want to start a sweep?")
					ig.SeparatorText("Starting a sweep will erase the previous sweep from memory.")
					if ig.Button("I'm sure I want to perminently erase data and start a new sweep.")
						unitvec = [seconds, minutes, hours]
						sweeptime = unitvec[iv_time_units+1](iv_sweep_time)
						errormonitor(Threads.@async start_iv_sweep(iv_min_volts, iv_max_volts, iv_step_voltage, iv_init_voltage, iv_sweep_dir, sweeptime))
						ig.CloseCurrentPopup()
					end
					ig.EndPopup()
				end
				if monitoring_keithley
					ig.SameLine()
					ig.TextColored((255,0,0,255), "Currently monitoring keithley,\n plese stop monitoring")
				end
				ig.EndTabItem()
			end
			if ig.BeginTabItem("Real Time Monitor")
				@c ig.CheckboxFlags("Fit X-Axis##rt", &rt_xflags, ImPlot.ImPlotAxisFlags_AutoFit)
				ig.SameLine()
				@c ig.CheckboxFlags("Fit Y-Axis##rt", &rt_yflags, ImPlot.ImPlotAxisFlags_AutoFit)
				if ImPlot.BeginPlot("Foo", "x1", "y1", ig.ImVec2(800, 800))
					ImPlot.SetupAxes("Time", "Current", rt_xflags, rt_yflags)
					ImPlot.PlotLine("realtime", realtime_x, realtime_y)
					ImPlot.EndPlot()
				end
				ig.SameLine()
				if ig.Button("Clear Data")
					ig.OpenPopup("clear_data_popup")
				end
				if ig.BeginPopupModal("clear_data_popup")
					ig.SeparatorText("Are you sure you want to erase the data?")
					ig.SeparatorText("")
					if ig.Button("I'm sure I want to perminently erase data.")
						empty!(keithley_realtime_data)
						empty!(realtime_x)
						empty!(realtime_y)
						ig.CloseCurrentPopup()
					end
					ig.EndPopup()
				end
				ig.PushItemWidth(150.0f0)
				@c ig.DragFloat("Set Voltage", &rt_set_volts, 0.001f0)
				if rt_prev_set_volts != rt_set_volts
					ig.SameLine()
					ig.TextColored((255,0,0,255), "Voltage not set, Stop and Resume data collection")
				end
				@c ig.DragFloat("Sample rate", &rt_smpl_rate, 0.1f0)
				ig.SameLine()
				ig.SetNextItemWidth(250.0f0)
				@c ig.Combo("Units", &rt_smpl_rate_unit, ["Micro Seconds", "Milli Seconds", "Seconds", "Minutes", "Hours", "Hz", "kHz"])
				units = [micros, millis, seconds, minutes, hours, Hz, kHz]
				keithley_sample_period = units[rt_smpl_rate_unit+1](rt_smpl_rate)
				ig.PopItemWidth()

				if !monitoring_keithley
					if !isempty(realtime_x)
						if ig.Button("Resume")
							monitoring_keithley = !monitoring_keithley
							rt_prev_set_volts = rt_set_volts
						end
					elseif ig.Button("Start")
						monitoring_keithley = !monitoring_keithley
						rt_prev_set_volts = rt_set_volts
					end
				else
					if ig.Button("Stop")
						monitoring_keithley = !monitoring_keithley
					end
				end
				ig.EndTabItem()
			end
			ig.EndTabBar()
		end

		# y = rand(1000)
		# ImPlot.SetNextAxesLimits(0.0,1000,0.0,1.0, ig.ImGuiCond_Once)
		
		ig.End()
	end
end


end # module KeithleyPico
