#CarbonFluxModel <- function(LakeName,PlotFlag,ValidationFlag){
#Flags 1 for yes, else no.
LakeName = 'Monona'

# With DOC ~ Inflow
# Parameters = c(0.647496073 0.002959697 0.758720514) #NLL 287
# With DOC ~! Inflow
# Parameters = c(0.84365741 0.00274874 0.78449935) #NLL 279
OptimizationFlag = 1
PlotFlag = 0
ValidationFlag = 1

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
library(dplyr)
library(plyr)

##### LOAD FUNCTIONS #######################
source("./R/Model/SOS_Sedimentation.R")
source("./R/Model/SOS_SWGW.R")
source("./R/Model/SOS_NPP.R")
source("./R/Model/SOS_Resp.R")
source("./R/Model/modelDOC_4.R")

##### READ MAIN INPUT FILE #################
RawData <- read.csv(TimeSeriesFile,header=T) #Read main data file with GLM outputs (physical input) and NPP input
#RawData$datetime <- as.POSIXct(strptime(RawData$datetime,"%m/%d/%Y %H:%M"),tz="GMT") #Convert time to POSIX
RawData$datetime <- as.POSIXct(strptime(RawData$datetime,"%Y-%m-%d"),tz="GMT") #Convert time to POSIX

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
#RainData$datetime <- as.POSIXct(strptime(RainData$datetime,'%m/%d/%Y',tz='GMT'))
RainData$datetime <- as.POSIXct(strptime(RainData$datetime,'%Y-%m-%d',tz='GMT'))

InputData$Rain <- RainData$Rain[RainData$datetime %in% InputData$datetime] #Plug daily rain data into InputData file to integrate with original code.

##### READ PARAMETER FILE ##################
parameters <- read.table(file = ParameterFile,header=TRUE,comment.char="#",stringsAsFactors = F)
for (i in 1:nrow(parameters)){ # assign parameters
  assign(parameters[i,1],parameters[i,2])
}

###### Run Period and Time Step Setup #####
TimeStep <- as.numeric(InputData$datetime[2]-InputData$datetime[1]) #days
steps <- nrow(InputData)

##### Declare Output Data Storage ##########
POC_df = data.frame(Date = InputData$datetime,
                    POC_conc_gm3 = NA,
                    NPPin_gm2y=NA,FlowIn_gm2y=NA,FlowOut_gm2y=NA,sedOut_gm2y=NA,leachOut_gm2y=NA,
                    POC_flowOut_gm2y = NA, POC_sedOut_gm2y = NA,
                    POCload_g = NA, POCalloch_g = NA, POCautoch_g = NA,
                    POCout_g = NA)
DOC_df = data.frame(Date = InputData$datetime,
                    DOC_conc_gm3 = NA,
                    NPPin_gm2y=NA,FlowIn_gm2y=NA,FlowOut_gm2y=NA,respOut_gm2y=NA,leachIn_gm2y=NA,
                    DOC_flowOut_gm2y = NA, DOC_respOut_gm2y = NA,
                    DOCload_g = NA, DOCalloch_g = NA, DOCautoch_g = NA,
                    DOCout_g = NA)

##### Declare Data Storage - Sed ###########
SedData <- data.frame(Date = InputData$datetime, BurialScalingFactor=NA,MAR_oc=NA,POC_burial=NA,POC_sedOut = NA)

##### Declare Data Storage - NPP ###########
NPPdata <- data.frame(Date = InputData$datetime,DOC_rate=NA,POC_rate=NA,DOC_mass=NA,POC_mass=NA, DOC_resp_mass=NA)
Metabolism <- data.frame(Date = InputData$datetime,NEP=NA,Oxygen=NA)

##### Declare Data Storage - SW/GW #########
SWGWData <- data.frame(Date = InputData$datetime,POC_Aerial=NA, POC_SW=NA, DOC_Wetland=NA, 
                       DOC_gw=NA, DOC_SW=NA, DailyRain=NA, DOC_precip=NA, Load_DOC=NA, Load_POC=NA,
                       POC_massIn_g = NA, DOC_massIn_g = NA, POC_outflow = NA, DOC_outflow = NA)

#### Declare Data Storage - POC to DOC Leaching ####
LeachData <- data.frame(Date = InputData$datetime,POC_leachOut = NA,DOC_leachIn = NA)

##### Declare Data Storage - Source of Sink? #
SOS <- data.frame(Date = InputData$datetime,Source=NA,Sink=NA,Pipe=NA,Net=NA)

##### Carbon Concentration Initialization ################
POC_df$POC_conc_gm3[1] <- POC_init # #Initialize POC concentration as baseline average
DOC_df$DOC_conc_gm3[1] <- DOC_init #Initialize DOC concentration g/m3

####################### Validation Output Setup ######################################

#DOC Validation Output Setup
ValidationDataDOC <- read.csv(ValidationFileDOC,header=T)
#ValidationDataDOC$datetime <- as.Date(as.POSIXct(strptime(ValidationDataDOC$datetime,"%m/%d/%Y %H:%M"),tz="GMT")) #Convert time to POSIX
ValidationDataDOC$datetime <- as.Date(as.POSIXct(strptime(ValidationDataDOC$datetime,"%Y-%m-%d"),tz="GMT")) #Convert time to POSIX
ValidationDataDOC = ValidationDataDOC[complete.cases(ValidationDataDOC),]
outlier.limit = (mean(ValidationDataDOC$DOC) + 3*(sd(ValidationDataDOC$DOC))) # Calculate mean + 3 SD of DOC column
ValidationDataDOC = ValidationDataDOC[ValidationDataDOC$DOC <= outlier.limit,] # Remove rows where DOC > outlier.limit
ValidationDataDOC = ddply(ValidationDataDOC,'datetime',summarize,DOC=mean(DOC))

#DO Validation Output Setup
ValidationDataDO <- read.csv(ValidationFileDO,header=T)
#ValidationDataDO$datetime <- as.Date(as.POSIXct(strptime(ValidationDataDO$datetime,"%m/%d/%Y %H:%M"),tz="GMT")) #Convert time to POSIX
ValidationDataDO$datetime <- as.Date(as.POSIXct(strptime(ValidationDataDO$datetime,"%Y-%m-%d"),tz="GMT")) #Convert time to POSIX
ValidationDataDO = ValidationDataDO[complete.cases(ValidationDataDO),]
#Only compare to DO data during "production season."
ValidationDataDO = ValidationDataDO[yday(ValidationDataDO$datetime)>ProdStartDay & yday(ValidationDataDO$datetime)<ProdEndDay,]
#ValidationDataDO = ValidationDataDO[ValidationDataDO$wtr >= 10,]

k <- 0.5 #m/d
PhoticDepth <- data.frame(datetime = InputData$datetime,PhoticDepth = log(100)/(1.7/InputData$Secchi))
IndxVal = ValidationDataDO$datetime %in% as.Date(PhoticDepth$datetime)
IndxPhotic = as.Date(PhoticDepth$datetime) %in% ValidationDataDO$datetime

ValidationDataDO = ValidationDataDO[IndxVal,]
DO_sat <- o2.at.sat(ValidationDataDO[,1:2])  
ValidationDataDO$Flux <- k*(ValidationDataDO$DO_con-DO_sat$do.sat)/PhoticDepth$PhoticDepth[IndxPhotic]
#SedData MAR OC 
ValidationDataMAROC <- ObservedMAR_oc #g/m2


#################### OPTIMIZATION ROUTINE ############################################
if (OptimizationFlag==1){
  min.calcModelNLL <- function(pars,ValidationDataDOC,ValidationDataDO,ValidationDataMAROC){
    modeled = modelDOC(pars[1],pars[2],pars[3])
    
    obsIndx = ValidationDataDOC$datetime %in% modeled$datetime
    modIndx = modeled$datetime %in% ValidationDataDOC$datetime
    CalibrationOutputDOC <- data.frame(datetime = ValidationDataDOC[obsIndx,]$datetime,
                                       Measured = ValidationDataDOC[obsIndx,]$DOC, Modelled = modeled[modIndx,]$DOC_conc)
    #resDOC = scale(CalibrationOutputDOC$Measured - CalibrationOutputDOC$Modelled,center = F)
    resDOC = (CalibrationOutputDOC$Measured - CalibrationOutputDOC$Modelled)
    obsIndx = ValidationDataDO$datetime %in% modeled$datetime
    modIndx = modeled$datetime %in% ValidationDataDO$datetime
    CalibrationOutputDO <- data.frame(datetime = ValidationDataDO[obsIndx,]$datetime,
                                      Measured = ValidationDataDO[obsIndx,]$Flux, Modelled = modeled[modIndx,]$MetabOxygen)
    
    #resDO = scale(CalibrationOutputDO$Measured - CalibrationOutputDO$Modelled,center = F)
    DOScale = 5
    resDO = (CalibrationOutputDO$Measured - CalibrationOutputDO$Modelled) * DOScale
    sedScale = 0.001
    resSedData = (mean(modeled$SedData_MAR,na.rm = T) - ValidationDataMAROC) * sedScale #not scaled because it is 1 value
    
    res = c(resDOC,resDO,rep(resSedData,length(resDOC)))
    #res = c(resDOC,resDO)
    
    nRes 	= length(res)
    SSE 	= sum(res^2)
    sigma2 	= SSE/nRes
    NLL 	= 0.5*((SSE/sigma2) + nRes*log(2*pi*sigma2))
    print(paste('NLL: ',NLL,sep=''))
    print(paste('parameters: ',pars,sep=''))
    return(NLL)
  }
  
  optimOut = optim(par = c(BurialFactor,RespParam,R_auto), min.calcModelNLL,ValidationDataDOC = ValidationDataDOC,
                   ValidationDataDO = ValidationDataDO,ValidationDataMAROC = ValidationDataMAROC, 
                   control = list(maxit = 75)) #setting maximum number of attempts for now
                   #method = 'L-BFGS-B',lower=c(0,0,0) #To constrain
  
  print('Parameter estimates (burial, Rhet, Raut...')
  print(optimOut$par)
  ## New parameters from optimization output
  
  conv <- optimOut$convergence  #did model converge or not (0=yes, 1=no)
  NLL <- optimOut$value #value of nll
  
  BurialFactor <- optimOut$par[1] #
  RespParam <- optimOut$par[2]
  R_auto <- optimOut$par[3]
}

####################### END OPTIMIZATION ROUTINE #################################
####################### MAIN PROGRAM #############################################

for (i in 1:(steps)){
  if (R_auto > 1){R_auto = 1}
  
  Q_sw <- InputData$FlowIn[i] #m3/s surface water flowrate at i
  Q_gw <- Q_sw/(1-PropGW) - Q_sw #m3/s; as a function of proportion of inflow that is GW
  Q_out <- InputData$FlowOut[i] #m3/s: total outflow. Assume steady state pending dynamic output
  Rainfall <- InputData$Rain[i]/TimeStep #mm/day
  
  #Call NPP Function
  PhoticDepth <- log(100)/(1.7/InputData$Secchi[i]) #Calc photic depth as function of Secchi depth
  if (PhoticDepth>LakeDepth){PhoticDepth<-LakeDepth} #QC - If photic depth calc'ed as greater than lake depth, photic depth = lake depth
  RawProduction <- NPP(InputData$Chla[i],InputData$TP[i],PhoticDepth,InputData$EpiTemp[i],yday(InputData$datetime[i])) #mg C/m^2/d
  NPPdata$DOC_rate[i] = RawProduction$NPP_DOC_rate
  NPPdata$POC_rate[i] = RawProduction$NPP_POC_rate
  
  #Call respiration function
  DOC_resp_rate <- Resp(DOC_df$DOC_conc_gm3[i],InputData$EpiTemp[i],RespParam) #g C/m3/d ##CHANGE TO AVERAGE OR LAYER TEMP WHEN AVAILABLE IN TIME SERIES
  NPPdata$DOC_resp_mass[i] = DOC_resp_rate*LakeVolume*TimeStep #g C
  # Calculations that do not have to be in the loop
  NPPdata$DOC_mass[i] <- NPPdata$DOC_rate[i]*(1-R_auto)*LakeArea*TimeStep/1000 #g
  NPPdata$POC_mass[i] <- NPPdata$POC_rate[i]*(1-R_auto)*LakeArea*TimeStep/1000 #g
  
  #Calc metabolism (DO) estimates for NPP validation
  Metabolism$NEP[i] <- (NPPdata$DOC_mass[i] + NPPdata$POC_mass[i] - NPPdata$DOC_resp_mass[i]*(PhoticDepth/LakeDepth))/(LakeVolume*PhoticDepth/LakeDepth)/TimeStep #g/m3/d
  Metabolism$Oxygen <- (Metabolism$NEP)*(32/12) #g/m3/d Molar conversion of C flux to O2 flux (lake metabolism)
  
  #Call SWGW Function
  SWGW <- SWGWFunction(Q_sw,Q_gw,Rainfall,AerialLoad, PropCanopy, LakePerimeter, WetlandLoad, PropWetlands, DOC_gw, 
                       InputData$SW_DOC[i], DOC_precip, LakeArea) #change these inputs to iterative [i] values when inputs are dynamic
  SWGWData[i,2:10] <- SWGW
  
  #Call Sedimentation Function
  POC_mass <- POC_df$POC_conc_gm3[i]*LakeVolume
  SedOutput <- SedimentationFunction(BurialFactor,TimeStep,POC_mass,LakeArea)
  SedData[i,2:4] = SedOutput
  SedData$POC_sedOut[i] <- SedData$POC_burial[i] #g #WHY IS THIS REPEATED?
  
  #Calc outflow subtractions (assuming outflow concentrations = mixed lake concentrations)
  SWGWData$POC_outflow[i] <- POC_df$POC_conc_gm3[i]*Q_out*60*60*24*TimeStep #g
  SWGWData$DOC_outflow[i] <- DOC_df$DOC_conc_gm3[i]*Q_out*60*60*24*TimeStep #g
  #Calculate load from SWGW_in
  SWGWData$DOC_massIn_g[i] <- SWGWData$Load_DOC[i]*TimeStep #g
  SWGWData$POC_massIn_g[i] <- SWGWData$Load_POC[i]*TimeStep #g
  #Calc POC-to-DOC leaching
  LeachData$POC_leachOut[i] <- POC_df$POC_conc_gm3[i]*POC_lc*LakeVolume*TimeStep #g - POC concentration times leaching parameter
  LeachData$DOC_leachIn[i] <- LeachData$POC_leachOut[i]
  
  if (i < steps) { #don't calculate for last time step
    #Update POC and DOC concentration values (g/m3) for whole lake
    POC_df$POC_conc_gm3[i+1] <-  POC_df$POC_conc_gm3[i] + ((NPPdata$POC_mass[i] + SWGWData$POC_massIn_g[i] - SWGWData$POC_outflow[i] - SedData$POC_sedOut[i] - LeachData$POC_leachOut[i])/LakeVolume) #g/m3
    DOC_df$DOC_conc_gm3[i+1] <-  DOC_df$DOC_conc_gm3[i] + ((NPPdata$DOC_mass[i] + SWGWData$DOC_massIn_g[i] + LeachData$DOC_leachIn[i] - SWGWData$DOC_outflow[i] - NPPdata$DOC_resp_mass[i])/LakeVolume) #g/m3
    #Stop code and output error if concentrations go to negative
    if (POC_df$POC_conc_gm3[i+1]<=0){stop("Negative POC concentration!")}
    if (DOC_df$DOC_conc_gm3[i+1]<=0){stop("Negative DOC concentration!")}
  }
}

#Store POC and DOC fluxes as mass/area/time (g/m2/yr)
POC_df$NPPin_gm2y <-  NPPdata$POC_mass/LakeArea/(TimeStep/365)
POC_df$FlowIn_gm2y <- SWGWData$POC_massIn_g/LakeArea/(TimeStep/365)
POC_df$FlowOut_gm2y <- SWGWData$POC_outflow/LakeArea/(TimeStep/365)
POC_df$sedOut_gm2y <- SedData$POC_sedOut/LakeArea/(TimeStep/365)
POC_df$leachOut_gm2y <- LeachData$POC_leachOut/LakeArea/(TimeStep/365)

DOC_df$NPPin_gm2y <- NPPdata$DOC_mass/LakeArea/(TimeStep/365)
DOC_df$FlowIn_gm2y <- SWGWData$DOC_massIn_g/LakeArea/(TimeStep/365)
DOC_df$FlowOut_gm2y <- SWGWData$DOC_outflow/LakeArea/(TimeStep/365) 
DOC_df$respOut_gm2y<- NPPdata$DOC_resp_mass/LakeArea/(TimeStep/365) 
DOC_df$leachIn_gm2y <- LeachData$DOC_leachIn/LakeArea/(TimeStep/365)

#Cumulative DOC and POC fate (grams)
POC_df$POC_flowOut_gm2y <- cumsum(SWGWData$POC_outflow)
POC_df$POC_sedOut_gm2y <- cumsum(SedData$POC_sedOut)
DOC_df$DOC_flowOut_gm2y = cumsum(SWGWData$DOC_outflow)
DOC_df$DOC_respOut_gm2y = cumsum(NPPdata$DOC_resp_mass)
#POC and DOC load (in) and fate (out) (g)
POC_df$POCload_g <- NPPdata$POC_mass + SWGWData$POC_massIn_g #g
POC_df$POCalloch_g <- SWGWData$POC_massIn_g
POC_df$POCautoch_g <- NPPdata$POC_mass
POC_df$POCout_g = SWGWData$POC_outflow + SedData$POC_sedOut + LeachData$POC_leachOut

DOC_df$DOCload_g <- NPPdata$DOC_mass + SWGWData$DOC_massIn_g #g
DOC_df$DOCalloch_g <- SWGWData$DOC_massIn_g
DOC_df$DOCautoch_g <- NPPdata$DOC_mass
DOC_df$DOCout_g = SWGWData$DOC_outflow + NPPdata$DOC_resp_mass #g

#OC mass sourced/sank at each time step
SOS$Sink <- SedData$POC_sedOut
SOS$Source <- SWGWData$POC_outflow + SWGWData$DOC_outflow + NPPdata$DOC_resp_mass - SWGWData$POC_massIn_g - SWGWData$DOC_massIn_g
SOS$Pipe <- SWGWData$POC_outflow + SWGWData$DOC_outflow + NPPdata$DOC_resp_mass - NPPdata$DOC_mass - SWGWData$POC_massIn_g
SOS$Net <- SOS$Sink - SOS$Source

############### MASS BALANCE CHECK ###############
#Change to total carbon stocks
FinalPOC <-  POC_df$POC_conc_gm3[steps] + ((NPPdata$POC_mass[steps] + SWGWData$POC_massIn_g[steps] - SWGWData$POC_outflow[steps] - SedData$POC_sedOut[steps] - LeachData$POC_leachOut[steps])/LakeVolume) #g/m3
FinalDOC <-  DOC_df$DOC_conc_gm3[steps] + ((NPPdata$DOC_mass[steps] + SWGWData$DOC_massIn_g[steps] + LeachData$DOC_leachIn[steps] - SWGWData$DOC_outflow[steps] - NPPdata$DOC_resp_mass[steps])/LakeVolume) #g/m3
DeltaPOC <- FinalPOC*LakeVolume -  POC_df$POC_conc_gm3[1]*LakeVolume #g
DeltaDOC <- FinalDOC*LakeVolume - DOC_df$DOC_conc_gm3[1]*LakeVolume #g
#Mass balance check (should be near zero)
POCcheck <- (sum(POC_df$POCalloch_g) + sum(POC_df$POCautoch_g) -  sum(POC_df$POCout_g)) - DeltaPOC
DOCcheck <- (sum(DOC_df$DOCalloch_g) + sum(DOC_df$DOCautoch_g) + sum(LeachData$DOC_leachIn) - sum(DOC_df$DOCout_g)) - DeltaDOC
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
                                    Measured = NA, Modelled = NA)
  CalibrationOutputDOC$datetime <- ValidationDataDOC$datetime[ValidationDOCIndeces]
  CalibrationOutputDOC$Measured <- ValidationDataDOC$DOC[ValidationDOCIndeces]
  CalibrationOutputDOC$Modelled <- DOC_df$DOC_conc_gm3[modIndx]
  
  #DO Validation Output Setup
  ValidationDOIndeces = ValidationDataDO$datetime %in% OutputTimeSeries
  modIndx = OutputTimeSeries %in% ValidationDataDO$datetime
  CalibrationOutputDO = data.frame(datetime = rep(NA,sum(ValidationDOIndeces)),
                                    Measured = NA, Modelled = NA)
  
  PhoticDepth <- data.frame(datetime = InputData$datetime,PhoticDepth = log(100)/(1.7/InputData$Secchi))
  DO_sat <- o2.at.sat(ValidationDataDO[,1:2])  
  IndxPhotic = as.Date(PhoticDepth$datetime) %in% ValidationDataDO$datetime
  
  CalibrationOutputDO$datetime <- ValidationDataDO$datetime[ValidationDOIndeces]
  CalibrationOutputDO$Measured <- k*(ValidationDataDO$DO_con-DO_sat$do.sat)[ValidationDOIndeces]/PhoticDepth$PhoticDepth[IndxPhotic]
  CalibrationOutputDO$Modelled <- Metabolism$Oxygen[modIndx]
  
  #Plot Calibration
  par(mfrow=c(2,1),mar=c(2,3,2,1),mgp=c(1.5,0.3,0),tck=-0.02)
  plot(CalibrationOutputDOC$datetime,CalibrationOutputDOC$Measured,type='o',pch=19,cex=0.5,ylab = 'DOC',xlab='',
       ylim = c(min(CalibrationOutputDOC[,2:3]),max(CalibrationOutputDOC[,2:3])),main=LakeName)
  lines(CalibrationOutputDOC$datetime,CalibrationOutputDOC$Modelled,col='red',lwd=2)
  lines(as.Date(DOC_df$Date),DOC_df$DOC_conc_gm3,col='darkgreen',lwd=2)
  legend('topleft',legend = c('observed','modeled'),lty = c(1,1),pch = c(16,NA),
         col = c('black','darkgreen'),bty='n',cex=0.8)
  
  plot(CalibrationOutputDO$datetime,CalibrationOutputDO$Measured,type='o',pch=19,cex=0.5,ylab = 'DO Flux',xlab='',
       ylim = c(min(CalibrationOutputDO[,2:3]),max(CalibrationOutputDO[,2:3])))
  lines(CalibrationOutputDO$datetime,CalibrationOutputDO$Modelled,col='darkgreen',lwd=2)
  abline(h=0,lty=2)
}

################## PLOTTING ###########################################################

if (PlotFlag==1){
  #POC and DOC concentration in time (g/m3)
  par(mar=c(2.5,3,1,1),mgp=c(1.5,0.3,0),tck=-0.02,cex=0.8)
  plot(OutputTimeSeries,DOC_df$DOC_conc_gm3,xlab='Date',ylab="DOC Conc (g/m3)",type="l")
  lines(ValidationDataDOC$datetime,ValidationDataDOC$DOC,col='red3')
}


