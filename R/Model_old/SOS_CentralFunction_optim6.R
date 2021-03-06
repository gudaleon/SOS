setwd('C:/Users/hdugan/Documents/Rpackages/SOS/')
setwd("~/Documents/Rpackages/SOS")
#CarbonFluxModel <- function(LakeName,PlotFlag,ValidationFlag){
#Flags 1 for yes, else no.
LakeName = 'Monona'
OptimizationFlag = 0
updateParameters = 0
PlotFlag = 1
ValidationFlag = 1
WriteFiles = 1
BootstrapFlag = 0
timestampFormat =	'%Y-%m-%d'
##### INPUT FILE NAMES ################
TimeSeriesFile <- paste('./',LakeName,'Lake/',LakeName,'TS.csv',sep='')
RainFile <- paste('./',LakeName,'Lake/',LakeName,'Rain.csv',sep='')
ParameterFile <- paste('./',LakeName,'Lake/','ConfigurationInputs',LakeName,'.txt',sep='')
ValidationFileDOC <- paste('./',LakeName,'Lake/',LakeName,'ValidationDOC.csv',sep='')
ValidationFileDO <- paste('./',LakeName,'Lake/',LakeName,'ValidationDO.csv',sep='')

##### LOAD PACKAGES ########################
library(signal)
library(zoo)
library(lubridate)
library(LakeMetabolizer)
library(plyr)
library(dplyr)

##### LOAD FUNCTIONS #######################
source("./R/Model/SOS_Sedimentation.R")
source("./R/Model/SOS_SWGW.R")
source("./R/Model/SOS_GPP.R")
source("./R/Model/SOS_Resp.R")
source("./R/Model/modelDOC_7.R")

##### READ PARAMETER FILE ##################
parameters <- read.table(file = ParameterFile,header=TRUE,comment.char="#",stringsAsFactors = F)
for (i in 1:nrow(parameters)){ # assign parameters
  assign(parameters[i,1],parameters[i,2])
}

##### READ MAIN INPUT FILE #################
RawData <- read.csv(TimeSeriesFile,header=T) #Read main data file with GLM outputs (physical input) and NPP input
RawData$datetime <- as.POSIXct(strptime(RawData$datetime,timestampFormat),tz="GMT") #Convert time to POSIX
cc = which(complete.cases(RawData))
RawData = RawData[cc[1]:tail(cc,1),]

# Fill time-series gaps (linear interpolation)
ts_new <- data.frame(datetime = seq(RawData$datetime[1],RawData$datetime[nrow(RawData)],by="day")) #Interpolate gapless time-series
InputData <- merge(RawData,ts_new,all=T)
for (col in 2:ncol(InputData)){
  InputData[,col] <- na.approx(InputData[,col],na.rm = T)}
InputData$Chla[InputData$Chla == 0] = 0.0001

##### READ RAIN FILE #######################
RainData <- read.csv(RainFile,header=T,stringsAsFactors = F) #Read daily rain file (units=mm) Read separately and added back to main file to avoid issues of linear interpolation with rain data in length units
RainData$datetime <- as.POSIXct(strptime(RainData$datetime,timestampFormat,tz='GMT'))

InputData$Rain <- RainData$Rain[RainData$datetime %in% InputData$datetime] #Plug daily rain data into InputData file to integrate with original code.

#### For TOOLIK ONLY #### (dealing with ice season)
if (LakeName=='Toolik'){
  # Set FlowIn to 0 for ice-on periods for Toolik Inlet, based on historical data: 
  # http://toolik.alaska.edu/edc/journal/annual_summaries.php?summary=inlet
  # Used average ice on/off dates from 2006-2010 for 2001-2005 (no data available those years)
  
  icepath = paste0(LakeName,'Lake','/','ToolikInlet_IceOn_IceOff.csv')
  IceOnOff = read.csv(icepath)
  IceOnOff$IceOff = as.POSIXct(strptime(IceOnOff$IceOff,"%m/%d/%Y %H:%M"),tz="GMT") #Convert time to POSIX
  IceOnOff$IceOn = as.POSIXct(strptime(IceOnOff$IceOn,"%m/%d/%Y %H:%M"),tz="GMT") #Convert time to POSIX
  #str(IceOnOff)
  
  ice_func <- function(year,off,on, dataframe){
    ## ARGUMENTS ##
    # year: 4 digits, in quotes as character ('2002')
    # off: month-day in quotes ('05-09') = May 9th
    # on: same structure as off
    # dataframe = name of dataframe of interest
    
    day1 = paste0(year,'-01-01')
    year_num = as.numeric(year)
    year_before = as.character(year_num - 1)
    day1 = paste0(year_before, '-12-31') # there was a bug; R thought >= Jan 1 meant Jan 2 (must be something internal with date structure)
    day365 = paste0(year, '-12-31')
    iceoff = paste0(year,'-',off)
    iceon = paste0(year,'-',on)
    # create annual subset for specific year
    annual_subset = dataframe[dataframe$datetime > day1 & dataframe$datetime <= day365,]
    
    # extract data for that year before ice off
    pre_thaw = annual_subset[annual_subset$datetime < iceoff,]
    pre_thaw$FlowIn = rep(0,length(pre_thaw$FlowIn)) # set FlowIn = 0 during ice time
    pre_thaw$FlowOut = pre_thaw$FlowIn # we assume flow out = flow in
    
    # extract data for that year for between ice off and ice on (ice free season)
    ice_free_season = annual_subset[annual_subset$datetime >= iceoff & annual_subset$datetime < iceon,]
    
    # extract data for that year for after fall ice on
    post_freeze = annual_subset[annual_subset$datetime >= iceon,]
    post_freeze$FlowIn = rep(0,length(post_freeze$FlowIn))
    post_freeze$FlowOut = post_freeze$FlowIn
    
    # combine 3 annual subsets (pre thaw, ice free season, post freeze)
    annual_corrected = rbind.data.frame(pre_thaw,ice_free_season,post_freeze)
    return(annual_corrected)
  }
  
  years = as.character(IceOnOff$Year)
  iceoff_dates = IceOnOff$IceOff
  iceoff_dates = format(iceoff_dates, format='%m-%d')
  iceon_dates = IceOnOff$IceOn
  iceon_dates = format(iceon_dates, format='%m-%d')
  
  for (i in 1:length(years)){
    for (j in 1:length(iceoff_dates)) {
      for (k in 1:length(iceon_dates)) {
        x = ice_func(year = years[i], off = iceoff_dates[j], on = iceon_dates[k], dataframe = InputData)
        assign(paste0(LakeName,years[i]),x)
        x = NULL #get rid of extra output with unassigned name
      }
    }
  }
  
  ## Combine annual data frames into single for lake
  # I know this isn't the most dynamic code, but I was having trouble making the above loop output a single DF
  InputData = rbind(Toolik2001,Toolik2002,Toolik2003,Toolik2004,Toolik2005,Toolik2006,
                    Toolik2007,Toolik2008,Toolik2009,Toolik2010)
  
}

###### Run Period and Time Step Setup #####
TimeStep <- as.numeric(InputData$datetime[2]-InputData$datetime[1]) #days
steps <- nrow(InputData)

##### Declare Output Data Storage ##########
POC_df = data.frame(Date = InputData$datetime, POCtotal_conc_gm3 = NA,
                    POCR_conc_gm3 = NA, POCL_conc_gm3 = NA,
                    NPPin_gm2y=NA,FlowIn_gm2y=NA,FlowOut_gm2y=NA,sedOut_gm2y=NA,leachOut_gm2y=NA,
                    POC_flowOut_gm2y = NA, POC_sedOut_gm2y = NA,
                    POCload_g = NA, POCalloch_g = NA, POCautoch_g = NA,
                    POCout_g = NA)
DOC_df = data.frame(Date = InputData$datetime,DOCtotal_conc_gm3 = NA,
                    DOCR_conc_gm3 = NA, DOCL_conc_gm3 = NA,
                    NPPin_gm2y=NA,FlowIn_gm2y=NA,FlowOut_gm2y=NA,respOut_gm2y=NA,leachIn_gm2y=NA,
                    DOC_flowOut_gm2y = NA, DOC_respOut_gm2y = NA,
                    DOCload_g = NA, DOCalloch_g = NA, DOCautoch_g = NA,
                    DOCout_g = NA)

##### Declare Data Storage - Sed ###########
SedData <- data.frame(Date = InputData$datetime,BurialScalingFactor_R=NA,MAR_oc_R=NA,POC_burial_R=NA,
                      BurialScalingFactor_L=NA,MAR_oc_L=NA,POC_burial_L=NA,
                      MAR_oc_total=NA,POC_burial_total=NA)

##### Declare Data Storage - NPP ###########
PPdata <- data.frame(Date = InputData$datetime,GPP_DOCL_rate=NA,GPP_POCL_rate=NA,NPP_DOCL_mass=NA,NPP_POCL_mass=NA, DOCL_massRespired=NA)
Metabolism <- data.frame(Date = InputData$datetime,NEP=NA,Oxygen=NA)

##### Declare Data Storage - SW/GW #########
SWGWData <- data.frame(Date = InputData$datetime,POCR_Aerial=NA, POCR_SW=NA, DOCR_Wetland=NA, 
                       DOCR_gw=NA, DOCR_SW=NA, DailyRain=NA, DOCR_precip=NA, Load_DOCR=NA, Load_POCR=NA,
                       POCR_massIn_g = NA, DOCR_massIn_g = NA, 
                       POCR_outflow = NA, DOCR_outflow = NA, POCL_outflow = NA, DOCL_outflow = NA)

#### Declare Data Storage - POC to DOC Leaching ####
LeachData <- data.frame(Date = InputData$datetime,POCR_leachOut = NA,DOCR_leachIn = NA,
                        POCL_leachOut = NA,DOCL_leachIn = NA)

##### Declare Data Storage - Source of Sink? #
SOS <- data.frame(Date = InputData$datetime,Source=NA,Sink=NA,Pipe=NA,Net=NA)

##### Carbon Concentration Initialization ################
POC_df$POCtotal_conc_gm3[1] <- POC_init # #Initialize POC concentration as baseline average
DOC_df$DOCtotal_conc_gm3[1] <- DOC_init #Initialize DOC concentration g/m3
DOC_df$DOCR_conc_gm3[1] <- DOC_init*0.8 #Initialize DOC concentration g/m3
DOC_df$DOCL_conc_gm3[1] <- DOC_init*0.2 #Initialize DOC concentration g/m3
POC_df$POCR_conc_gm3[1] <- POC_init*0.8 #Initialize POC concentration g/m3
POC_df$POCL_conc_gm3[1] <- POC_init*0.2 #Initialize POC concentration g/m3

####################### Validation Output Setup ######################################

#DOC Validation Output Setup
ValidationDataDOC <- read.csv(ValidationFileDOC,header=T)
ValidationDataDOC$datetime <- as.Date(as.POSIXct(strptime(ValidationDataDOC$datetime,timestampFormat),tz="GMT")) #Convert time to POSIX
ValidationDataDOC = ValidationDataDOC[complete.cases(ValidationDataDOC),]
outlier.limit = (mean(ValidationDataDOC$DOC) + 3*(sd(ValidationDataDOC$DOC))) # Calculate mean + 3 SD of DOC column
ValidationDataDOC = ValidationDataDOC[ValidationDataDOC$DOC <= outlier.limit,] # Remove rows where DOC > outlier.limit
ValidationDataDOC = ddply(ValidationDataDOC,'datetime',summarize,DOC=mean(DOC),DOCwc=mean(DOCwc))

#DO Validation Output Setup
ValidationDataDO <- read.csv(ValidationFileDO,header=T)
ValidationDataDO$datetime <- as.Date(as.POSIXct(strptime(ValidationDataDO$datetime,timestampFormat),tz="GMT")) #Convert time to POSIX
ValidationDataDO = ValidationDataDO[complete.cases(ValidationDataDO),]
#Only compare to DO data during "production season."
ValidationDataDO = ValidationDataDO[yday(ValidationDataDO$datetime)>ProdStartDay & yday(ValidationDataDO$datetime)<ProdEndDay,]
#ValidationDataDO = ValidationDataDO[ValidationDataDO$wtr >= 10,]

k <- 0.5 #m/d
PhoticDepth <- data.frame(datetime = InputData$datetime,PhoticDepth = log(100)/(1.7/InputData$Secchi))
IndxVal = ValidationDataDO$datetime %in% as.Date(PhoticDepth$datetime)
IndxPhotic = as.Date(PhoticDepth$datetime) %in% ValidationDataDO$datetime

ValidationDataDO = ValidationDataDO[IndxVal,]
ValidationDataDO$DO_sat <- o2.at.sat(ValidationDataDO[,1:2])[,2]  
ValidationDataDO$Flux <- k*(ValidationDataDO$DO_con - ValidationDataDO$DO_sat)/(PhoticDepth$PhoticDepth[IndxPhotic]) #g/m3/d
#SedData MAR OC 
ValidationDataMAROC <- ObservedMAR_oc #g/m2

#################### OPTIMIZATION ROUTINE ############################################
if (OptimizationFlag==1) {
  min.calcModelNLL <- function(pars,ValidationDataDOC,ValidationDataDO,ValidationDataMAROC){
    modeled = modelDOC(pars[1],pars[2],pars[3],pars[4],pars[5],pars[6],pars[7])
    
    #modeled = modelDOC(optimOut$par[1],optimOut$par[2],optimOut$par[3],optimOut$par[4],optimOut$par[5],optimOut$par[6],optimOut$par[7])
    # DOC
    obsIndx = ValidationDataDOC$datetime %in% modeled$datetime
    modIndx = modeled$datetime %in% ValidationDataDOC$datetime
    CalibrationOutputDOC <- data.frame(datetime = ValidationDataDOC[obsIndx,]$datetime,
                                       Measured = ValidationDataDOC[obsIndx,]$DOC, Modelled = modeled[modIndx,]$DOC_conc)
    resDOC = (CalibrationOutputDOC$Measured - CalibrationOutputDOC$Modelled)
    resMDOC = CalibrationOutputDOC$Measured - mean(CalibrationOutputDOC$Measured)
    
    # Dissolved oxygen 
    obsIndx = ValidationDataDO$datetime %in% modeled$datetime
    modIndx = modeled$datetime %in% ValidationDataDO$datetime
    CalibrationOutputDO <- data.frame(datetime = ValidationDataDO[obsIndx,]$datetime,
                                      Measured = ValidationDataDO[obsIndx,]$Flux, Modelled = modeled[modIndx,]$MetabOxygen)
    
    # Scale residuals
    DOScale = 5
    resDO = (CalibrationOutputDO$Measured - CalibrationOutputDO$Modelled) * DOScale
    resMDO = (CalibrationOutputDO$Measured - mean(CalibrationOutputDO$Measured)) * DOScale
    #sedScale = 0.001
    #resSedData = (mean(modeled$SedData_MAR,na.rm = T) - ValidationDataMAROC) * sedScale #not scaled because it is 1 value
    
    if (length(resDO) > length(resDOC)){
      resExtras = sample(x = resDOC,size = length(resDO)-length(resDOC),replace = T)
      resMExtras = sample(x = resMDOC,size = length(resDO)-length(resDOC),replace = T)
      res = c(resDOC,resExtras,resDO) # residual string
      resM = c(resMDOC,resMExtras,resMDO)
    } else {
      res = c(resDOC,resDO) # residual string
      resM = c(resMDOC,resMDO)
    }

    
    MSRE = sqrt((1/length(res))*sum((res)^2)) # mean square root error 
    print(paste('MSRE: ',MSRE,sep=''))
    
    NashSutcliffe = 1 - (sum(res^2)/sum(resM^2))
    print(paste('NashSutcliffe: ',NashSutcliffe,sep=''))

    # 
    # nRes 	= length(res)
    # SSE 	= sum(res^2)
    # sigma2 	= SSE/nRes
    # NLL 	= 0.5*((SSE/sigma2) + nRes*log(2*pi*sigma2))
    # print(paste('NLL: ',NLL,sep=''))
    print(paste('parameters: ',pars,sep=''))
    return(NashSutcliffe)
  }
  ## Test call ##
  # min.calcModelNLL(par = c(DOCR_RespParam,DOCL_RespParam,R_auto,BurialFactor_R,BurialFactor_L,POC_lcR,POC_lcL),ValidationDataDOC = ValidationDataDOC,
  #                  ValidationDataDO = ValidationDataDO,ValidationDataMAROC = ValidationDataMAROC)
  # # # 
  
  optimOut = optim(par = c(DOCR_RespParam,DOCL_RespParam,R_auto,BurialFactor_R,BurialFactor_L,POC_lcR,POC_lcL), 
                   min.calcModelNLL,ValidationDataDOC = ValidationDataDOC,
                   ValidationDataDO = ValidationDataDO,ValidationDataMAROC = ValidationDataMAROC, 
                    control = list(maxit = 300,fnscale = -1)) #setting maximum number of attempts for now 
  # To maximize, set control(fnscale = -1) # Use this for Nash Sutcliffe Efficiency
  # method = 'L-BFGS-B',lower=c(0,0,0) #To constrain
  
  print('Parameter estimates (burial, Rhet, Raut...')
  print(optimOut$par)
  ## New parameters from optimization output
  
  conv <- optimOut$convergence  #did model converge or not (0=yes, 1=no)
  NLL <- optimOut$value #value of nll
  
  DOCR_RespParam <- optimOut$par[1]
  DOCL_RespParam <- optimOut$par[2]
  R_auto <- optimOut$par[3]
  BurialFactor_R <- optimOut$par[4]
  BurialFactor_L <- optimOut$par[5] 
  POC_lcR <- optimOut$par[6]
  POC_lcL <- optimOut$par[7]
}

if (updateParameters == 1){
  parameters[parameters$Parameter == 'DOCR_RespParam',2] = DOCR_RespParam
  parameters[parameters$Parameter == 'DOCL_RespParam',2] = DOCL_RespParam
  parameters[parameters$Parameter == 'R_auto',2] = R_auto
  parameters[parameters$Parameter == 'BurialFactor_R',2] = BurialFactor_R
  parameters[parameters$Parameter == 'BurialFactor_L',2] = BurialFactor_L
  parameters[parameters$Parameter == 'POC_lcR',2] = POC_lcR
  parameters[parameters$Parameter == 'POC_lcL',2] = POC_lcL
  write.table(parameters,file = ParameterFile,quote = F,row.names = F)
}

# 
# ####################### END OPTIMIZATION ROUTINE #################################
# ####################### MAIN PROGRAM #############################################
# Monona6: 0.0004087905  0.0041632723  0.8289424909  0.0709289391  0.1154835122 -0.0124340428  0.0293172223 #NLL 292
# Vanern6: 0.001399777 0.007491947 0.492280939 0.484148905 0.319265033 0.126942579 0.058335812 #NLL = -3.8
# Harp6:  -0.00005946672  0.00018709297  1.05954101066  0.46449228346 -0.79595429675 -0.35752906422  0.84667877472
# Trout6: 0.022287511  0.004949596  0.707380976  0.479660939 -0.022603197 -0.309983554  0.480108134
# Toolik6: 0.009217922 -0.181475814  0.621733535  0.237056611  0.034073382 -0.200121215  0.238469810


# POC_lcR = 0.01
# POC_lcL = 0.01
# BurialFactor_R = 0.05
# R_auto = 0.75


for (i in 1:(steps)) {
  if (R_auto > 1){R_auto = 1}
  
  Q_sw <- InputData$FlowIn[i] #m3/s surface water flowrate at i
  Q_gw <- Q_sw/(1-PropGW) - Q_sw #m3/s; as a function of proportion of inflow that is GW
  Q_out <- InputData$FlowOut[i] #m3/s: total outflow. Assume steady state pending dynamic output
  Rainfall <- InputData$Rain[i]/TimeStep #mm/day
  
  #Call GPP function
  PhoticDepth <- log(100)/(1.7/InputData$Secchi[i]) #Calc photic depth as function of Secchi depth
  if (PhoticDepth>LakeDepth){PhoticDepth<-LakeDepth} #QC - If photic depth calc'ed as greater than lake depth, photic depth = lake depth
  GPPrates <- GPP(InputData$Chla[i],InputData$TP[i],PhoticDepth,InputData$EpiTemp[i],yday(InputData$datetime[i])) #mg C/m^2/d
  PPdata$GPP_DOCL_rate[i] = 0 #mg C/m2/d
  PPdata$GPP_POCL_rate[i] = GPPrates$GPP_POC_rate + GPPrates$GPP_DOC_rate #mg C/m2/d #All NPP in POC
  PPdata$NPP_DOCL_mass[i] <- PPdata$GPP_DOCL_rate[i]*(1-R_auto)*LakeArea*TimeStep/1000 #g
  PPdata$NPP_POCL_mass[i] <- PPdata$GPP_POCL_rate[i]*(1-R_auto)*LakeArea*TimeStep/1000 #g
  
  #Call heterotrophic respiration function for recalitrant DOC pool (DOCR) and labile DOC pool (DOCL)
  DOCR_resp_rate <- Resp(DOC_df$DOCR_conc_gm3[i],InputData$EpiTemp[i],DOCR_RespParam) #g C/m3/d
  DOCL_resp_rate <- Resp(DOC_df$DOCL_conc_gm3[i],InputData$EpiTemp[i],DOCL_RespParam) #g C/m3/d ##CHANGE TO AVERAGE OR LAYER TEMP WHEN AVAILABLE IN TIME SERIES
  
  PPdata$DOCR_massRespired[i] = DOCR_resp_rate*LakeVolume*TimeStep #g C
  PPdata$DOCL_massRespired[i] = DOCL_resp_rate*LakeVolume*TimeStep #g C
  
  #Calc metabolism (DO) estimates for PP validation
  Metabolism$NEP[i] <- (PPdata$NPP_DOCL_mass[i] + PPdata$NPP_POCL_mass[i] - PPdata$DOCR_massRespired[i] - PPdata$DOCL_massRespired[i])/
    (LakeVolume*PhoticDepth/LakeDepth)/TimeStep #g/m3/d #volume of photic zone
  # Metabolism$NEP[i] <- (PPdata$NPP_DOCL_mass[i] + PPdata$NPP_POCL_mass[i] - PPdata$DOCR_massRespired[i] - PPdata$DOCL_massRespired[i])/
  #   (LakeVolume*PhoticDepth/LakeDepth)/TimeStep #g/m3/d #volume of photic zone
  Metabolism$Oxygen[i] <- (Metabolism$NEP[i])*(32/12) #g/m3/d Molar conversion of C flux to O2 flux (lake metabolism)
  
  #Call SWGW Function (Surface Water/GroundWater)
  SWGW <- SWGWFunction(Q_sw,Q_gw,Rainfall,AerialLoad, PropCanopy, LakePerimeter, WetlandLoad, PropWetlands, DOC_gw, 
                       InputData$SW_DOC[i], DOC_precip, LakeArea) # All in g/day, except DailyRain in m3/day
  #change these inputs to iterative [i] values when inputs are dynamic
  SWGWData[i,2:10] <- SWGW
  #LOAD DOC (g/d) = DOC_Wetland + DOC_GW + DOC_SW +DOC_Precip # g/d DOC
  #LOAD POC (g/d) = POC_Aerial + POC_SW # g/d POC roughly estimated as (0.1 * DOC)
  
  #Call Sedimentation Function
  POCR_mass <- POC_df$POCR_conc_gm3[i]*LakeVolume
  POCL_mass <- POC_df$POCL_conc_gm3[i]*LakeVolume
  SedOutput_R <- SedimentationFunction(BurialFactor_R,TimeStep,POCR_mass,LakeArea)
  SedOutput_L <- SedimentationFunction(BurialFactor_L,TimeStep,POCL_mass,LakeArea)
  SedData[i,2:4] = SedOutput_R
  SedData[i,5:7] = SedOutput_L
  SedData[i,8:9] = (SedOutput_L + SedOutput_R) [2:3]
  
  #Calc outflow subtractions (assuming outflow concentrations = mixed lake concentrations)
  SWGWData$POCR_outflow[i] <- POC_df$POCR_conc_gm3[i]*Q_out*60*60*24*TimeStep #g
  SWGWData$POCL_outflow[i] <- POC_df$POCL_conc_gm3[i]*Q_out*60*60*24*TimeStep #g
  SWGWData$DOCR_outflow[i] <- DOC_df$DOCR_conc_gm3[i]*Q_out*60*60*24*TimeStep #g
  SWGWData$DOCL_outflow[i] <- DOC_df$DOCL_conc_gm3[i]*Q_out*60*60*24*TimeStep #g
  #Calculate load from SWGW_in
  SWGWData$DOCR_massIn_g[i] <- SWGWData$Load_DOCR[i]*TimeStep #g
  SWGWData$POCR_massIn_g[i] <- SWGWData$Load_POCR[i]*TimeStep #g
  #Calc POC-to-DOC leaching
  LeachData$POCR_leachOut[i] <- POC_df$POCR_conc_gm3[i]*POC_lcR*LakeVolume*TimeStep #g - POC concentration times leaching parameter
  LeachData$DOCR_leachIn[i] <- LeachData$POCR_leachOut[i]
  LeachData$POCL_leachOut[i] <- POC_df$POCL_conc_gm3[i]*POC_lcL*LakeVolume*TimeStep #g - POC concentration times leaching parameter
  LeachData$DOCL_leachIn[i] <- LeachData$POCL_leachOut[i]
  
  if (i < steps) { #don't calculate for last time step
    #Update POC and DOC concentration values (g/m3) for whole lake
    
    POC_df$POCL_conc_gm3[i+1] <-  POC_df$POCL_conc_gm3[i] + ((PPdata$NPP_POCL_mass[i] - LeachData$POCL_leachOut[i] - SWGWData$POCL_outflow[i] - SedData$POC_burial_L[i])/LakeVolume) #g/m3
    POC_df$POCR_conc_gm3[i+1] <-  POC_df$POCR_conc_gm3[i] + ((SWGWData$POCR_massIn_g[i] - LeachData$POCR_leachOut[i] - SWGWData$POCR_outflow[i] - SedData$POC_burial_R[i])/LakeVolume)
    POC_df$POCtotal_conc_gm3[i+1] = POC_df$POCR_conc_gm3[i+1] + POC_df$POCL_conc_gm3[i+1]
    
    DOC_df$DOCL_conc_gm3[i+1] <- DOC_df$DOCL_conc_gm3[i] + ((PPdata$NPP_DOCL_mass[i] + LeachData$DOCL_leachIn[i] - SWGWData$DOCL_outflow[i] - PPdata$DOCL_massRespired[i])/LakeVolume) #g/m3
    DOC_df$DOCR_conc_gm3[i+1] <- DOC_df$DOCR_conc_gm3[i] + ((SWGWData$DOCR_massIn_g[i] + LeachData$DOCR_leachIn[i] - SWGWData$DOCR_outflow[i] - PPdata$DOCR_massRespired[i])/LakeVolume) #g/m3
    DOC_df$DOCtotal_conc_gm3[i+1] = DOC_df$DOCR_conc_gm3[i+1] + DOC_df$DOCL_conc_gm3[i+1]
    
    #Stop code and output error if concentrations go to negative
    # if (POC_df$POCtotal_conc_gm3[i+1]<=0){stop("Negative POC concentration!")}
    if (DOC_df$DOCtotal_conc_gm3[i+1]<=0){stop("Negative DOC concentration!")}
  }
}

#Store POC and DOC fluxes as mass/area/time (g/m2/yr)
POC_df$NPPin_gm2y <-  PPdata$NPP_POCL_mass/LakeArea/(TimeStep/365)
POC_df$FlowIn_gm2y <- SWGWData$POCR_massIn_g/LakeArea/(TimeStep/365)
POC_df$FlowOut_gm2y <- (SWGWData$POCR_outflow + SWGWData$POCL_outflow)/LakeArea/(TimeStep/365)
POC_df$sedOut_gm2y <- SedData$POC_burial_total/LakeArea/(TimeStep/365)
POC_df$leachOut_gm2y <- (LeachData$POCR_leachOut + LeachData$POCL_leachOut)/LakeArea/(TimeStep/365)

DOC_df$NPPin_gm2y <- PPdata$NPP_DOCL_mass/LakeArea/(TimeStep/365)
DOC_df$FlowIn_gm2y <- SWGWData$DOCR_massIn_g/LakeArea/(TimeStep/365)
DOC_df$FlowOut_gm2y <- (SWGWData$DOCR_outflow + SWGWData$DOCL_outflow)/LakeArea/(TimeStep/365) 
DOC_df$respOut_gm2y<- (PPdata$DOCR_massRespired + PPdata$DOCL_massRespired)/LakeArea/(TimeStep/365) 
DOC_df$leachIn_gm2y <- (LeachData$DOCR_leachIn + LeachData$DOCL_leachIn)/LakeArea/(TimeStep/365)

#Cumulative DOC and POC fate (grams)
POC_df$POC_flowOut_gm2y <- cumsum(SWGWData$POCR_outflow + SWGWData$POCL_outflow)
POC_df$POC_sedOut_gm2y <- cumsum(SedData$POC_burial_total)
DOC_df$DOC_flowOut_gm2y = cumsum(SWGWData$DOCR_outflow + SWGWData$DOCL_outflow)
DOC_df$DOC_respOut_gm2y = cumsum(PPdata$DOCR_massRespired + PPdata$DOCL_massRespired)

#POC and DOC load (in) and fate (out) (g)
POC_df$POCload_g <- PPdata$NPP_POCL_mass + SWGWData$POCR_massIn_g #g
POC_df$POCalloch_g <- SWGWData$POCR_massIn_g
POC_df$POCautoch_g <- PPdata$NPP_POCL_mass
POC_df$POCout_g = SWGWData$POCR_outflow + SWGWData$POCL_outflow + SedData$POC_burial_total + LeachData$POCR_leachOut + LeachData$POCL_leachOut

DOC_df$DOCload_g <- PPdata$NPP_DOCL_mass + SWGWData$DOCR_massIn_g + LeachData$DOCR_leachIn + LeachData$DOCL_leachIn #g
DOC_df$DOCalloch_g <- SWGWData$DOCR_massIn_g
DOC_df$DOCautoch_g <- LeachData$POCL_leachOut
DOC_df$DOCout_g <- SWGWData$DOCR_outflow + SWGWData$DOCL_outflow + PPdata$DOCR_massRespired + PPdata$DOCL_massRespired #g

#OC mass sourced/sank at each time step
# SOS$Sink <- SedData$POC_sedOut
# SOS$Source <- SWGWData$POC_outflow + SWGWData$DOC_outflow + NPPdata$DOC_resp_mass - SWGWData$POC_massIn_g - SWGWData$DOC_massIn_g
# SOS$Pipe <- SWGWData$POC_outflow + SWGWData$DOC_outflow + NPPdata$DOC_resp_mass - NPPdata$DOC_mass - SWGWData$POC_massIn_g
# SOS$Net <- SOS$Sink - SOS$Source

############### MASS BALANCE CHECK ###############
#Change to total carbon stocks
FinalPOC <- POC_df$POCtotal_conc_gm3[steps] + (POC_df$POCload_g[steps] - POC_df$POCout_g[steps])/LakeVolume #g/m3
FinalDOC <- DOC_df$DOCtotal_conc_gm3[steps] + (DOC_df$DOCload_g[steps] - DOC_df$DOCout_g[steps])/LakeVolume #g/m3
#FinalPOC <-  POC_df$POC_conc_gm3[steps] + ((NPPdata$POC_mass[steps] + SWGWData$POC_massIn_g[steps] - SWGWData$POC_outflow[steps] - SedData$POC_sedOut[steps] - LeachData$POC_leachOut[steps])/LakeVolume) #g/m3
#FinalDOC <-  DOC_df$DOC_conc_gm3[steps] + ((NPPdata$DOC_mass[steps] + SWGWData$DOC_massIn_g[steps] + LeachData$DOC_leachIn[steps] - SWGWData$DOC_outflow[steps] - NPPdata$DOC_resp_mass[steps])/LakeVolume) #g/m3
DeltaPOC <- FinalPOC*LakeVolume -  POC_df$POCtotal_conc_gm3[1]*LakeVolume #g
DeltaDOC <- FinalDOC*LakeVolume - DOC_df$DOCtotal_conc_gm3[1]*LakeVolume #g
#Mass balance check (should be near zero)
POCcheck <- sum(POC_df$POCload_g -POC_df$POCout_g) - DeltaPOC
DOCcheck <- sum(DOC_df$DOCload_g - DOC_df$DOCout_g) - DeltaDOC

#Return mass balance checks
print(paste('POC Balance: ',POCcheck,' and DOC Balance: ',DOCcheck,sep=''))

######################## END MAIN PROGRAM #############################################
#Define plotting and validation time series
ConcOutputTimeSeries <- as.Date(c(InputData$datetime,InputData$datetime[length(InputData$datetime)]+86400))
OutputTimeSeries <- as.Date(InputData$datetime)

####################### Validation Output Setup ######################################
if (ValidationFlag==1){
  
  #DOC Validation Output Setup
  ValidationDOCIndeces = ValidationDataDOC$datetime %in% OutputTimeSeries
  modIndx = OutputTimeSeries %in% ValidationDataDOC$datetime
  
  CalibrationOutputDOC = data.frame(datetime = rep(NA,sum(ValidationDOCIndeces)),
                                    Measured = NA, MeasuredWC = NA ,Modelled = NA)
  CalibrationOutputDOC$datetime <- ValidationDataDOC$datetime[ValidationDOCIndeces]
  CalibrationOutputDOC$Measured <- ValidationDataDOC$DOC[ValidationDOCIndeces]
  CalibrationOutputDOC$MeasuredWC <- ValidationDataDOC$DOCwc[ValidationDOCIndeces]
  CalibrationOutputDOC$Modelled <- DOC_df$DOCtotal_conc_gm3[modIndx]
  
  #DO Validation Output Setup
  ValidationDataDO_match = ValidationDataDO[ValidationDataDO$datetime %in% OutputTimeSeries,]
  modIndx = OutputTimeSeries %in% ValidationDataDO_match$datetime
  CalibrationOutputDO = data.frame(datetime = ValidationDataDO_match$datetime,
                                   Measured = NA, Modelled = NA)
  
  PhoticDepth <- data.frame(datetime = InputData$datetime,PhoticDepth = log(100)/(1.7/InputData$Secchi))
  PhoticDepth$PhoticDepth[PhoticDepth$PhoticDepth > LakeDepth] = LakeDepth
  DO_sat <- o2.at.sat(ValidationDataDO_match[,1:2])  
  IndxPhotic = as.Date(PhoticDepth$datetime) %in% ValidationDataDO_match$datetime
  
  CalibrationOutputDO$Measured <- k*(ValidationDataDO_match$DO_con-DO_sat$do.sat) /(PhoticDepth$PhoticDepth[IndxPhotic]) #mg/m2
  CalibrationOutputDO$Modelled <- Metabolism$Oxygen[modIndx]
  
  #Plot Calibration DOC
  par(mfrow=c(2,1),mar=c(2,3,2,1),mgp=c(1.5,0.3,0),tck=-0.02)
  plot(CalibrationOutputDOC$datetime,CalibrationOutputDOC$Measured,type='o',pch=19,cex=0.7,ylab = 'DOC',xlab='',
       ylim = c(min(CalibrationOutputDOC[,2:3]),max(CalibrationOutputDOC[,2:3])),main=LakeName)
  lines(CalibrationOutputDOC$datetime,CalibrationOutputDOC$Modelled,col='red',lwd=2)
  lines(as.Date(DOC_df$Date),DOC_df$DOC_conc_gm3,col='darkgreen',lwd=2)
  abline(v = as.Date(paste0(unique(year(DOC_df$Date)),'-01-01')),lty=2,col='grey50') #lines at Jan 1
  abline(v = as.Date(paste0(unique(year(DOC_df$Date)),'-06-01')),lty=3,col='grey80') #lines at Jul 1
  
  #Plot Calibration DO
  plot(CalibrationOutputDO$datetime,CalibrationOutputDO$Measured,type='o',pch=19,cex=0.7,ylab = 'DO Flux',xlab='',
       ylim = c(min(CalibrationOutputDO[,2:3],na.rm = T),max(CalibrationOutputDO[,2:3],na.rm = T)))
  lines(CalibrationOutputDO$datetime,CalibrationOutputDO$Modelled,col='darkgreen',lwd=2)
  abline(h=0,lty=2)
  abline(v = as.Date(paste0(unique(year(DOC_df$Date)),'-01-01')),lty=2,col='grey50') #lines at Jan 1
  abline(v = as.Date(paste0(unique(year(DOC_df$Date)),'-06-01')),lty=3,col='grey80') #lines at Jul 1
}

################## PLOTTING ###########################################################

if (PlotFlag==1){
  #POC and DOC concentration in time (g/m3)
  par(mar=c(2.5,3,1,1),mgp=c(1.5,0.3,0),tck=-0.02,cex=0.8)
  plot(OutputTimeSeries,DOC_df$DOCtotal_conc_gm3,xlab='Date',ylab="DOC Conc (g/m3)",type="l")
  lines(ValidationDataDOC$datetime,ValidationDataDOC$DOC,col='red3',type='o')
}
################## Calc goodness of fit #################

RMSE_DOC <- sqrt((1/length(CalibrationOutputDOC[,1]))*sum((CalibrationOutputDOC[,2]-CalibrationOutputDOC[,4])^2)) #mg^2/L^2
RMSE_DO <- sqrt((1/length(CalibrationOutputDO[,1]))*sum((CalibrationOutputDO[,2]-CalibrationOutputDO[,3])^2)) #mg^2/L^2
print(paste0('RMSE DOC ',RMSE_DOC))
print(paste0('RMSE DO ',RMSE_DO))

################## Bootstrapping of Residuals #################
if (BootstrapFlag==1){
  #save.image(file = "R/Model/lake.RData")
  
  resids <- CalibrationOutputDOC[,4]-CalibrationOutputDOC[,2]
  set.seed(001) # just to make it reproducible
  #set number of psuedo observations
  pseudoObs = matrix(replicate(4,sample(resids) + CalibrationOutputDOC$Measured),ncol = length(resids)) # matrix of psuedo observations 
  
  library(parallel)
  detectCores() # Calculate the number of cores
  cl <- makeCluster(4) # SET THIS NUMBER EQUAL TO OR LESS THAN THE CORES YOU HAVE
  
  source('R/Model/bootstrapDOC.R')
  # This applies the bootstrap function across multiple cores, works for Mac. 
  bootOut = parApply(cl = cl,MARGIN = 1,X = pseudoObs, FUN = bootstrapDOC,
                     datetime = CalibrationOutputDOC$datetime, LakeName = LakeName,
                     timestampFormat = timestampFormat)
  # Output results
  write.csv(bootOut,paste0('./',LakeName,'Lake/','Results/',LakeName,'_boostrapResults.csv'),row.names = F,quote=F)
  
  ###### This code be written as a loop instead. 
  bootParams = data.frame(DOCR_RespParam=NA,DOCL_RespParam=NA,R_auto=NA,BurialFactor_R=NA,
                          BurialFactor_L=NA,POC_lcR=NA,POC_lcL=NA,NLL = NA, Convergence = NA)
  for (b in 1:100) {
    pseudoDOC = data.frame(datetime = CalibrationOutputDOC$datetime, DOC = pseudoObs[b,], DOCwc = pseudoObs[b,])

    loopOut = bootstrapDOC(pseudoObs[1,],datetime = CalibrationOutputDOC$datetime, LakeName = LakeName,
                 timestampFormat = timestampFormat)
    ## New parameters from optimization output
    bootParams[b,] <- loopOut
  } # Loop instead?
}


################## Write results files ##################
if (WriteFiles==1){
  DOC_results_filename = paste('./',LakeName,'Lake/','Results/',LakeName,'_DOC_Results.csv',sep='')
  POC_results_filename = paste('./',LakeName,'Lake/','Results/',LakeName,'_POC_Results.csv',sep='')
  Input_filename = paste('./',LakeName,'Lake/','Results/',LakeName,'_InputData.csv',sep='')
  DOC_validation_filename = paste('./',LakeName,'Lake/','Results/',LakeName,'_DOCvalidation.csv',sep='')
  DO_validation_filename = paste('./',LakeName,'Lake/','Results/',LakeName,'_DOvalidation.csv',sep='')
  DO_results_filename = paste('./',LakeName,'Lake/','Results/',LakeName,'_DO_Results.csv',sep='')
  
  write.csv(DOC_df,file = DOC_results_filename,row.names = F,quote = F)
  write.csv(POC_df,file = POC_results_filename,row.names = F,quote = F)
  write.csv(InputData,file = Input_filename,row.names = F,quote = F)
  write.csv(CalibrationOutputDOC,file = DOC_validation_filename,row.names = F,quote = F)
  write.csv(CalibrationOutputDO,file = DO_validation_filename,row.names = F,quote = F)
  
  Metabolism$Oxygen_Area = Metabolism$Oxygen * PhoticDepth$PhoticDepth
  write.csv(Metabolism,file = DO_results_filename,row.names = F,quote = F)
  
}

