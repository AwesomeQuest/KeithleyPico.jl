module KeithleyPico


import CImGui as ig, ModernGL, GLFW
import CSyntax: @c
import ImPlot


# using Instruments
using Dates

global keithley_realtime_data = Tuple{DateTime, Float32, Float32}[]
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

	iv_start_volts::Float32	= -1.0
	iv_stop_volts::Float32	= 1.0
	iv_step_number::Int32	= 100
	iv_sweep_time::Float32	= 10.0
	iv_time_units::Int32	= 0
	xs = range(iv_start_volts,iv_stop_volts, iv_step_number)
	ivsweep_x = [xs; reverse(xs)]
	ivsweep_y = [x + 2x^3 for x in ivsweep_x] .+ cumsum(0.05(rand(length(ivsweep_x)) .- 0.5))

	realtime_x = collect(1:1000)
	realtime_y = cumsum(rand(1000) .-0.5)
	rt_set_volts::Float32 = 1.0f0
	function generatedata()
		realtime_x = collect(1:1000)
		realtime_y = cumsum(rand(1000) .-0.5)
		xs = range(iv_start_volts,iv_stop_volts, iv_step_number)
		ivsweep_x = [xs; reverse(xs)]
		ivsweep_y = [x + 2x^3 for x in ivsweep_x] .+ cumsum(0.05(rand(length(ivsweep_x)) .- 0.5))
	end

	monitoring_keithley = false

	show_style_editor = false

	ig.render(ctx; window_size=(1200,1200), window_title="Keithley Pico", on_exit=() -> ImPlot.DestroyContext(p_ctx)) do
		
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

		if ig.Button("Generate new data")
			generatedata()
			ImPlot.SetNextAxesToFit()
		end

		if ig.BeginTabBar("MyTabBar", ig.ImGuiTabBarFlags_NoCloseWithMiddleMouseButton)
			if ig.BeginTabItem("I-V Sweep")
				if ImPlot.BeginPlot("Foo", "x1", "y1", ig.ImVec2(800, 800))
					ImPlot.PlotLine("data", ivsweep_x, ivsweep_y)
					ImPlot.EndPlot()
				end
				@c ig.DragFloat("Start Voltage", &iv_start_volts, 0.01f0)
				@c ig.DragFloat("Stop Voltage",  &iv_stop_volts, 0.01f0)
				@c ig.DragInt("Number of steps",  &iv_step_number)
				@c ig.DragFloat("Sweep time",    &iv_sweep_time, 0.1f0)
				ig.SameLine()
				@c ig.Combo("Time Units", &iv_time_units, ["Seconds", "Minutes", "Hours"])
				ig.EndTabItem()
			end
			if ig.BeginTabItem("Real Time Monitor")
				ImPlot.SetNextAxesToFit()
				if ImPlot.BeginPlot("Foo", "x1", "y1", ig.ImVec2(800, 800))
					if isempty(realtime_x)
						push!(realtime_x, 1)
						push!(realtime_y, rand()-0.5)
					end
					push!(realtime_x, realtime_x[end]+1)
					push!(realtime_y, realtime_y[end]+rand()-0.5)
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
				@c ig.DragFloat("Set Voltage", &rt_set_volts, 0.001f0)
				if !monitoring_keithley
					if !isempty(keithley_realtime_data)
						if ig.Button("Resume")
							monitoring_keithley = !monitoring_keithley
						end
					elseif ig.Button("Start")
						monitoring_keithley = !monitoring_keithley
						push!(keithley_realtime_data, (now(), 1.0,0.2))
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
